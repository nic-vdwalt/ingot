"""Cook step for INGMESH2 bundles.

Takes triangle meshes, produces LOD chains, optional cluster DAGs, and the
serialized bundle. Deliberately dependency-free: it must run inside Blender's
bundled Python, which is the only interpreter guaranteed to be present when
`bash build.sh assets` runs.

The simplifier here mirrors `ingot/procgen/mesh_simplify.odin` decision for
decision - position grouping, collapse onto an existing vertex, locked borders,
and the frozen fan around a locked vertex - and the index-order passes mirror
`ingot/procgen/mesh_optimize.odin` the same way. The two implementations exist
because the cook runs offline in Python and the terrain builder runs at load
time in Odin; `ingot/docs/cluster-lod.md` is the contract they both answer to.

Formats are specified in `ingot/docs/cooked-mesh-v2.md`. Nothing here writes a
file; `write_bundle` is the only I/O and it writes atomically.
"""

import heapq
import math
import os
import struct
import tempfile

MAGIC = b"INGMESH2"
VERSION = 2
HEADER_SIZE = 48
RECORD_SIZE = 68
LOD_SIZE = 24
CLUSTER_SIZE = 40
GROUP_SIZE = 32

FLAG_PACKED_VERTICES = 1 << 0
FLAG_CLUSTERS = 1 << 1

MAX_MESHES = 1024
MAX_MESH_LODS = 8
MAX_BYTES = 256 * 1024 * 1024

CLUSTER_MAX_TRIANGLES = 128
CLUSTER_GROUP_SIZE = 4
CLUSTER_MAX_LEVELS = 32
CLUSTER_ERROR_ROOT = struct.unpack("<f", struct.pack("<I", 0x7F7FFFFF))[0]
CLUSTER_GROUP_NONE = 0xFFFFFFFF
CLUSTER_ERROR_STEP = 1.0e-6

SIMPLIFY_MAX_PASSES = 32
SIMPLIFY_PASS_RATIO = 0.2
SIMPLIFY_BOUNDARY_WEIGHT = 1000.0
SIMPLIFY_EPSILON = 1.0e-12

PACKED_POSITION_RANGE = 65535.0
PACKED_UV_RANGE = 65535.0
PACKED_NORMAL_RANGE = 127.0
PACKED_SCALAR_RANGE = 255.0
PACKED_SCALAR_MAX = 2.0

# Ratio of LOD 0's indices to keep at each level. LOD 0 is always the cleaned
# source: the old pipeline's fixed 4,000-face decimate happened before cooking
# and threw detail away permanently, where a chain keeps it and spends it only
# where the camera can see it.
LOD_POLICIES = {
    "none": (1.0,),
    "grass_2": (1.0, 0.25),
    "grass_blades_2": (1.0, 0.25),
    "structure_3": (1.0, 0.5, 0.2),
    "tree_4": (1.0, 0.5, 0.25, 0.08),
}

# Projected height in pixels below which a level is preferred. Strictly
# decreasing, because two levels that qualify at once would make the runtime's
# choice depend on iteration order.
LOD_SCREEN_BASE = 1024.0
LOD_SCREEN_FALLOFF = 4.0


class CookError(ValueError):
    """Raised for any input the cook step refuses. Callers report and exit."""


def fail(message):
    raise CookError(message)


# -- vertex helpers -----------------------------------------------------------
# A vertex is a 9-tuple: position xyz, normal xyz, scalar, uv xy. That is the
# shape `blender_ingmesh_export.py` already produces, kept unchanged so the cook
# step is a pure addition to the pipeline rather than a rewrite of it.

POSITION = slice(0, 3)
NORMAL = slice(3, 6)
SCALAR = 6
UV = slice(7, 9)


def bounds_of(vertices):
    if not vertices:
        fail("cannot bound an empty mesh")
    minimum = [min(vertex[axis] for vertex in vertices) for axis in range(3)]
    maximum = [max(vertex[axis] for vertex in vertices) for axis in range(3)]
    return tuple(minimum), tuple(maximum)


def uv_bounds_of(vertices):
    if not vertices:
        fail("cannot bound an empty mesh")
    minimum = [min(vertex[7 + axis] for vertex in vertices) for axis in range(2)]
    maximum = [max(vertex[7 + axis] for vertex in vertices) for axis in range(2)]
    return tuple(minimum), tuple(maximum)


def _finite(value):
    return isinstance(value, float) and math.isfinite(value)


def validate_mesh(vertices, indices, label):
    if not vertices or not indices:
        fail(f"{label}: mesh must contain indexed triangles")
    if len(indices) % 3:
        fail(f"{label}: index count {len(indices)} is not a multiple of three")
    for vertex in vertices:
        if len(vertex) != 9 or not all(_finite(float(value)) for value in vertex):
            fail(f"{label}: vertex has a non-finite or malformed attribute")
    for index in indices:
        if not 0 <= index < len(vertices):
            fail(f"{label}: index {index} is out of range")


# -- index optimisation -------------------------------------------------------
# Mirrors `ingot/procgen/mesh_optimize.odin`. The two implementations exist
# because this cook runs inside Blender's bundled interpreter and the runtime
# cook runs in Odin, so neither can call the other. `test_mesh_cook.py` and
# `procgen/mesh_optimize_test.odin` assert the same golden index order, which is
# what keeps that duplication honest.

CACHE_SIZE = 32
# The three most recent vertices score flat, so the corners of the triangle just
# emitted do not compete with each other for the front of the cache.
CACHE_RECENT = 3
CACHE_RECENT_SCORE = 0.75
VALENCE_SCALE = 2.0
OVERDRAW_THRESHOLD = 1.05
OVERDRAW_RUN_DIVISOR = 8.0


def optimize_vertex_cache(indices, vertex_count, cache_size=CACHE_SIZE):
    """Tom Forsyth's linear-speed vertex cache reordering.

    Reorders triangles so a GPU's post-transform cache is reused. It is a pure
    permutation - the mesh is unchanged - and it is close to free at cook time,
    which is why it runs unconditionally rather than behind a flag.
    """
    triangle_count = len(indices) // 3
    if triangle_count < 2:
        return list(indices)
    adjacency = [[] for _ in range(vertex_count)]
    for triangle in range(triangle_count):
        for corner in range(3):
            adjacency[indices[triangle * 3 + corner]].append(triangle)
    remaining = [len(entries) for entries in adjacency]
    cache_position = [-1] * vertex_count
    live = [True] * triangle_count
    scores = [_vertex_score(-1, remaining[vertex]) for vertex in range(vertex_count)]
    triangle_scores = [
        sum(scores[indices[triangle * 3 + corner]] for corner in range(3))
        for triangle in range(triangle_count)
    ]
    stamp = [0] * triangle_count
    heap = [
        (-triangle_scores[triangle], triangle, 0) for triangle in range(triangle_count)
    ]
    heapq.heapify(heap)
    cache = []
    output = []
    for _ in range(triangle_count):
        best = _best_triangle(heap, stamp, live)
        if best < 0:
            break
        live[best] = False
        corners = [indices[best * 3 + corner] for corner in range(3)]
        output.extend(corners)
        evicted = []
        for vertex in corners:
            remaining[vertex] -= 1
            if vertex in cache:
                cache.remove(vertex)
            cache.insert(0, vertex)
        # Three insertions can push at most three vertices off the end. Their
        # modelled position has to be cleared: leaving the stale slot behind
        # would keep the cache bonus in an evicted vertex's score indefinitely
        # and inflate every triangle that still references it.
        while len(cache) > cache_size:
            dropped = cache.pop()
            cache_position[dropped] = -1
            evicted.append(dropped)
        for slot, vertex in enumerate(cache):
            cache_position[vertex] = slot
        touched = set()
        for vertex in set(corners) | set(cache) | set(evicted):
            score = _vertex_score(cache_position[vertex], remaining[vertex])
            # A vertex whose modelled position and valence both held still
            # scores the same as it did, so every triangle around it is already
            # correct. The skip is exact rather than approximate, which is why
            # both implementations can take it without diverging.
            if score == scores[vertex]:
                continue
            scores[vertex] = score
            touched.update(adjacency[vertex])
        for triangle in touched:
            if not live[triangle]:
                continue
            score = sum(scores[indices[triangle * 3 + corner]] for corner in range(3))
            if score == triangle_scores[triangle]:
                continue
            triangle_scores[triangle] = score
            stamp[triangle] += 1
            heapq.heappush(heap, (-score, triangle, stamp[triangle]))
    if len(output) != len(indices):
        # A disconnected or degenerate input can starve the walk; falling back
        # to the original order is always correct, just not optimised.
        return list(indices)
    return output


def _best_triangle(heap, stamp, live):
    """Highest-scoring live triangle, ties resolved to the lowest index.

    A lazy-deletion heap: a rescored triangle is pushed again under a fresh
    stamp and the stale entry is discarded on the way past. This replaced a
    linear scan over every live triangle, which was O(T^2) - fine for the small
    props Blender cooks, a hang for the terrain chunks the runtime cook sees.

    The `(-score, triangle)` key reproduces that scan exactly rather than
    merely closely: the scan walked upward taking a strictly better score, so it
    too kept the lowest index among equals. `procgen/mesh_optimize.odin` orders
    its heap the same way.
    """
    while heap:
        negated, triangle, entry = heapq.heappop(heap)
        if not live[triangle] or entry != stamp[triangle]:
            continue
        # The rejection floor. Reaching it means every remaining triangle has a
        # vertex with no work left, which a well-formed mesh cannot produce.
        if -negated <= -1.0:
            return -1
        return triangle
    return -1


def _vertex_score(cache_position, remaining):
    """Forsyth's score, spelled so another language reproduces it bit for bit.

    `sqrt` is correctly rounded per IEEE-754 where `pow` is not, and
    equal-valence vertices produce exactly tied scores often enough that a
    last-ulp disagreement between two libms would flip a tie and diverge the
    whole output order. So x**1.5 is written x*sqrt(x) and 2*n**-0.5 is written
    2/sqrt(n) - the same values, reproducible on every platform.
    `procgen/mesh_optimize.odin` spells them the same way, and that is the only
    reason the golden order is shareable at all.
    """
    # A vertex with no triangles left is worthless, and scoring it below every
    # reachable score is what lets the walk detect a starved mesh.
    if remaining <= 0:
        return -1.0
    score = 0.0
    if cache_position >= 0:
        if cache_position < CACHE_RECENT:
            score = CACHE_RECENT_SCORE
        else:
            offset = cache_position - CACHE_RECENT
            ramp = 1.0 - offset / (CACHE_SIZE - CACHE_RECENT)
            score = ramp * math.sqrt(ramp)
    return score + VALENCE_SCALE / math.sqrt(remaining)


def optimize_overdraw(vertices, indices, threshold=OVERDRAW_THRESHOLD):
    """View-independent overdraw reduction.

    Splits the cache-optimised order into hard boundaries, then sorts those runs
    front to back by distance from the mesh centre. It is a weaker heuristic
    than a true depth sort and it is allowed to give back a little cache
    efficiency, bounded by `threshold`.
    """
    triangle_count = len(indices) // 3
    if triangle_count < 2:
        return list(indices)
    center = [
        sum(vertex[axis] for vertex in vertices) / len(vertices) for axis in range(3)
    ]
    divisor = max(1.0, threshold * OVERDRAW_RUN_DIVISOR)
    runs = _split_runs(indices, max(1, int(triangle_count / divisor)))
    keyed = []
    for start, count in runs:
        distance = 0.0
        for triangle in range(start, start + count):
            for corner in range(3):
                vertex = vertices[indices[triangle * 3 + corner]]
                distance += sum((vertex[axis] - center[axis]) ** 2 for axis in range(3))
        keyed.append((distance / (count * 3), start, count))
    keyed.sort()
    output = []
    for _, start, count in keyed:
        output.extend(indices[start * 3 : (start + count) * 3])
    return output


def _split_runs(indices, run_length):
    triangle_count = len(indices) // 3
    run_length = max(1, run_length)
    runs = []
    start = 0
    while start < triangle_count:
        count = min(run_length, triangle_count - start)
        runs.append((start, count))
        start += count
    return runs


def optimize_vertex_fetch(vertices, indices):
    """Renumber vertices into first-use order so fetches run forward."""
    remap = {}
    output_vertices = []
    output_indices = []
    for index in indices:
        slot = remap.get(index)
        if slot is None:
            slot = len(output_vertices)
            remap[index] = slot
            output_vertices.append(vertices[index])
        output_indices.append(slot)
    return output_vertices, output_indices


def optimize(vertices, indices):
    """Cache, then overdraw, then fetch - the order the passes assume."""
    ordered = optimize_vertex_cache(indices, len(vertices))
    ordered = optimize_overdraw(vertices, ordered)
    return optimize_vertex_fetch(vertices, ordered)


# -- quadric simplification ---------------------------------------------------
# Mirrors ingot/procgen/mesh_simplify.odin. See ingot/docs/cluster-lod.md for
# why collapses move onto existing vertices and why a locked vertex's whole
# triangle fan is frozen rather than just the vertex itself.

FLAG_LOCKED = 1
FLAG_PROTECTED = 2


def _quadric(normal, offset, weight):
    a, b, c = normal
    return (
        a * a * weight,
        a * b * weight,
        a * c * weight,
        a * offset * weight,
        b * b * weight,
        b * c * weight,
        b * offset * weight,
        c * c * weight,
        c * offset * weight,
        offset * offset * weight,
        weight,
    )


def _quadric_add(first, second):
    return tuple(first[index] + second[index] for index in range(11))


def _quadric_error(quadric, point):
    x, y, z = point
    result = quadric[0] * x * x + 2 * quadric[1] * x * y + 2 * quadric[2] * x * z
    result += 2 * quadric[3] * x + quadric[4] * y * y + 2 * quadric[5] * y * z
    result += 2 * quadric[6] * y + quadric[7] * z * z + 2 * quadric[8] * z
    result += quadric[9]
    # The eleventh slot is the accumulated plane weight. Dividing by it turns
    # the metric into a mean squared distance, so a LOD error is a length in
    # mesh units rather than a number scaled by how much boundary the region
    # happened to contain.
    return max(result, 0.0) / max(quadric[10], SIMPLIFY_EPSILON)


ZERO_QUADRIC = (0.0,) * 11


def _position_groups(vertices):
    """Topology is resolved positionally, or a normal or UV seam would pin the
    whole surface and nothing would simplify."""
    representative = {}
    group = [0] * len(vertices)
    for index, vertex in enumerate(vertices):
        key = vertex[POSITION]
        slot = representative.get(key)
        if slot is None:
            representative[key] = index
            slot = index
        group[index] = slot
    return group


def _face_plane(vertices, corners):
    first = vertices[corners[0]][POSITION]
    second = vertices[corners[1]][POSITION]
    third = vertices[corners[2]][POSITION]
    edge_a = [second[axis] - first[axis] for axis in range(3)]
    edge_b = [third[axis] - first[axis] for axis in range(3)]
    crossed = (
        edge_a[1] * edge_b[2] - edge_a[2] * edge_b[1],
        edge_a[2] * edge_b[0] - edge_a[0] * edge_b[2],
        edge_a[0] * edge_b[1] - edge_a[1] * edge_b[0],
    )
    area = math.sqrt(sum(value * value for value in crossed))
    if area <= SIMPLIFY_EPSILON:
        return None, 0.0
    return tuple(value / area for value in crossed), area


def _edge_table(indices, group):
    edges = {}
    for triangle in range(len(indices) // 3):
        corners = [group[indices[triangle * 3 + corner]] for corner in range(3)]
        for corner in range(3):
            first = corners[corner]
            second = corners[(corner + 1) % 3]
            if first == second:
                continue
            key = (min(first, second), max(first, second))
            entry = edges.get(key)
            if entry is None:
                edges[key] = [1, triangle]
            else:
                entry[0] += 1
    return edges


def _build_quadrics(vertices, indices, group, edges, lock_boundary, flags):
    quadrics = {}
    for triangle in range(len(indices) // 3):
        corners = [group[indices[triangle * 3 + corner]] for corner in range(3)]
        normal, area = _face_plane(vertices, corners)
        if normal is None:
            continue
        point = vertices[corners[0]][POSITION]
        offset = -sum(normal[axis] * point[axis] for axis in range(3))
        plane = _quadric(normal, offset, area)
        for corner in corners:
            quadrics[corner] = _quadric_add(quadrics.get(corner, ZERO_QUADRIC), plane)
    for (low, high), (count, triangle) in edges.items():
        if count != 1:
            continue
        if lock_boundary:
            flags[low] = flags.get(low, 0) | FLAG_LOCKED
            flags[high] = flags.get(high, 0) | FLAG_LOCKED
            continue
        corners = [group[indices[triangle * 3 + corner]] for corner in range(3)]
        face, area = _face_plane(vertices, corners)
        if face is None:
            continue
        low_point = vertices[low][POSITION]
        high_point = vertices[high][POSITION]
        direction = [high_point[axis] - low_point[axis] for axis in range(3)]
        crossed = (
            face[1] * direction[2] - face[2] * direction[1],
            face[2] * direction[0] - face[0] * direction[2],
            face[0] * direction[1] - face[1] * direction[0],
        )
        length = math.sqrt(sum(value * value for value in crossed))
        if length <= SIMPLIFY_EPSILON:
            continue
        normal = tuple(value / length for value in crossed)
        offset = -sum(normal[axis] * low_point[axis] for axis in range(3))
        plane = _quadric(normal, offset, area * SIMPLIFY_BOUNDARY_WEIGHT)
        quadrics[low] = _quadric_add(quadrics.get(low, ZERO_QUADRIC), plane)
        quadrics[high] = _quadric_add(quadrics.get(high, ZERO_QUADRIC), plane)
    return quadrics


def _lock_fans(indices, group, flags):
    """A locked vertex whose whole fan contracts vanishes from the output - the
    exact crack the lock existed to prevent. Freezing every triangle that
    touches one makes that impossible."""
    for triangle in range(len(indices) // 3):
        corners = [group[indices[triangle * 3 + corner]] for corner in range(3)]
        if not any(flags.get(corner, 0) & FLAG_LOCKED for corner in corners):
            continue
        for corner in corners:
            flags[corner] = flags.get(corner, 0) | FLAG_PROTECTED


def _rebuild(indices, group, collapse):
    output = []
    for triangle in range(len(indices) // 3):
        corners = []
        for corner in range(3):
            original = indices[triangle * 3 + corner]
            owner = group[original]
            destination = collapse.get(owner, owner)
            corners.append(original if destination == owner else destination)
        resolved = [group[corner] for corner in corners]
        if len(set(resolved)) != 3:
            continue
        output.extend(corners)
    return output


def simplify(vertices, indices, target_index_count, locked=None, lock_boundary=False):
    """Reduce toward `target_index_count`; returns (vertices, indices, error).

    `locked` is a per-vertex mask. A locked position is never a collapse source
    and, because collapses only move onto existing vertices, survives at
    bit-identical coordinates.
    """
    working = list(indices)
    group = _position_groups(vertices)
    collapse = {}
    worst = 0.0
    for _ in range(SIMPLIFY_MAX_PASSES):
        if target_index_count > 0 and len(working) <= target_index_count:
            break
        flags = {}
        if locked is not None:
            for index, is_locked in enumerate(locked):
                if is_locked:
                    flags[group[index]] = flags.get(group[index], 0) | FLAG_LOCKED
        edges = _edge_table(working, group)
        if not edges:
            break
        quadrics = _build_quadrics(vertices, working, group, edges, lock_boundary, flags)
        _lock_fans(working, group, flags)
        candidates = _candidates(vertices, edges, quadrics, flags)
        if not candidates:
            break
        applied, worst = _apply(candidates, collapse, quadrics, flags, worst)
        if applied == 0:
            break
        working = _rebuild(working, group, collapse)
        if not working:
            break
    # `working` already reflects every accepted collapse; compaction drops the
    # vertices no surviving triangle references any more.
    result_vertices, result_indices = optimize_vertex_fetch(vertices, working)
    return result_vertices, result_indices, math.sqrt(max(worst, 0.0))


def _candidates(vertices, edges, quadrics, flags):
    candidates = []
    for low, high in edges:
        low_locked = flags.get(low, 0) != 0
        high_locked = flags.get(high, 0) != 0
        if low_locked and high_locked:
            continue
        combined = _quadric_add(
            quadrics.get(low, ZERO_QUADRIC), quadrics.get(high, ZERO_QUADRIC)
        )
        low_cost = _quadric_error(combined, vertices[high][POSITION])
        high_cost = _quadric_error(combined, vertices[low][POSITION])
        if low_locked or (not high_locked and high_cost < low_cost):
            candidates.append((max(high_cost, 0.0), high, low))
        else:
            candidates.append((max(low_cost, 0.0), low, high))
    # A total order, so ties do not depend on dictionary iteration.
    candidates.sort()
    return candidates


def _apply(candidates, collapse, quadrics, flags, worst):
    budget = max(1, int(len(candidates) * SIMPLIFY_PASS_RATIO))
    touched = set()
    applied = 0
    for cost, source, destination in candidates:
        if applied >= budget:
            break
        if source in touched or destination in touched:
            continue
        if collapse.get(source, source) != source:
            continue
        if collapse.get(destination, destination) != destination:
            continue
        if flags.get(source, 0) != 0:
            continue
        collapse[source] = destination
        quadrics[destination] = _quadric_add(
            quadrics.get(destination, ZERO_QUADRIC), quadrics.get(source, ZERO_QUADRIC)
        )
        touched.add(source)
        touched.add(destination)
        worst = max(worst, cost)
        applied += 1
    return applied, worst


# -- LOD chains ---------------------------------------------------------------


class Lod:
    __slots__ = ("vertices", "indices", "error", "threshold")

    def __init__(self, vertices, indices, error, threshold):
        self.vertices = vertices
        self.indices = indices
        self.error = error
        self.threshold = threshold


BLADE_MAX_COUNT = 256
BLADE_MAX_TRIANGLES = 128


def _blade_boundary(triangles, label):
    edges = {}
    for triangle in triangles:
        for start, end in zip(triangle, triangle[1:] + triangle[:1]):
            edge = (start, end)
            edges[edge] = edges.get(edge, 0) + 1
            if edges[edge] > 1:
                fail(f"{label}: overlapping or nonmanifold blade faces")
    boundary = {edge for edge in edges if (edge[1], edge[0]) not in edges}
    if not boundary:
        fail(f"{label}: empty blade patch boundary")
    outgoing = {}
    incoming = {}
    for start, end in boundary:
        if start in outgoing or end in incoming:
            fail(f"{label}: ambiguous blade patch boundary")
        outgoing[start] = end
        incoming[end] = start
    if set(outgoing) != set(incoming):
        fail(f"{label}: open blade patch boundary")
    start = min(outgoing)
    cursor = start
    visited = set()
    for _ in range(len(boundary)):
        if cursor in visited:
            fail(f"{label}: disconnected blade patch")
        visited.add(cursor)
        cursor = outgoing[cursor]
    if cursor != start:
        fail(f"{label}: invalid blade patch cycle")
    return boundary


def _validate_patch_outline(boundary, triangles, label):
    normal, _ = _blade_patch_geometry(triangles[0], label)
    drop = max(range(3), key=lambda axis: abs(normal[axis]))
    axes = [axis for axis in range(3) if axis != drop]
    edges = sorted(boundary)
    def orientation(start, end, point):
        return ((end[axes[0]] - start[axes[0]]) * (point[axes[1]] - start[axes[1]]) -
                (end[axes[1]] - start[axes[1]]) * (point[axes[0]] - start[axes[0]]))
    for index, (start, end) in enumerate(edges):
        for other_start, other_end in edges[index + 1:]:
            if {start, end} & {other_start, other_end}:
                continue
            first = orientation(start, end, other_start)
            second = orientation(start, end, other_end)
            third = orientation(other_start, other_end, start)
            fourth = orientation(other_start, other_end, end)
            if first * second <= 0 and third * fourth <= 0:
                minimum = [max(min(start[axis], end[axis]),
                               min(other_start[axis], other_end[axis])) for axis in axes]
                maximum = [min(max(start[axis], end[axis]),
                               max(other_start[axis], other_end[axis])) for axis in axes]
                if all(low <= high for low, high in zip(minimum, maximum)):
                    fail(f"{label}: self-intersecting blade patch")
    signed_area = sum(start[axes[0]] * end[axes[1]] - end[axes[0]] * start[axes[1]]
                      for start, end in edges)
    triangle_area = sum(orientation(*triangle) for triangle in triangles)
    if abs(signed_area - triangle_area) > max(abs(signed_area) * 1e-7, 1e-12):
        fail(f"{label}: overlapping blade patch coverage")


def _blade_patch_geometry(triangle, label):
    origin, second, third = triangle
    delta = tuple(second[axis] - origin[axis] for axis in range(3))
    other = tuple(third[axis] - origin[axis] for axis in range(3))
    cross = (delta[1] * other[2] - delta[2] * other[1],
             delta[2] * other[0] - delta[0] * other[2],
             delta[0] * other[1] - delta[1] * other[0])
    magnitude = math.sqrt(sum(value * value for value in cross))
    if not math.isfinite(magnitude) or magnitude <= 1e-14:
        fail(f"{label}: degenerate blade triangle")
    normal = tuple(value / magnitude for value in cross)
    return normal, magnitude


def _validate_blade_faces(triangles, label):
    patches = []
    for triangle in triangles:
        normal, area = _blade_patch_geometry(triangle, label)
        matches = []
        for index, patch in enumerate(patches):
            reference, origin, _, _ = patch
            alignment = sum(normal[axis] * reference[axis] for axis in range(3))
            distance = max(abs(sum(reference[axis] * (point[axis] - origin[axis])
                                   for axis in range(3))) for point in triangle)
            if abs(alignment) > 1 - 1e-7 and distance <= 1e-7:
                matches.append((index, alignment))
        if len(matches) > 1:
            fail(f"{label}: ambiguous coplanar blade patches")
        if not matches:
            patches.append((normal, triangle[0], [triangle], [area]))
        else:
            index, alignment = matches[0]
            patches[index][2].append(triangle)
            patches[index][3].append(area if alignment > 0 else -area)
    patch_edges = {}
    for patch_index, (_, _, faces, areas) in enumerate(patches):
        front = [face for face, area in zip(faces, areas) if area > 0]
        for start, end in _blade_boundary(front, label):
            edge = tuple(sorted((start, end)))
            owners = patch_edges.setdefault(edge, set())
            owners.add(patch_index)
            if len(owners) > 2:
                fail(f"{label}: nonmanifold blade segment junction")
    connected = {0}
    adjacency = [set() for _ in patches]
    for owners in patch_edges.values():
        for owner in owners:
            adjacency[owner].update(owners - {owner})
    for _ in range(len(patches)):
        expanded = connected | {neighbor for owner in connected for neighbor in adjacency[owner]}
        if expanded == connected:
            break
        connected = expanded
    if len(connected) != len(patches):
        fail(f"{label}: disconnected blade segments")
    for _, _, faces, areas in patches:
        front = [face for face, area in zip(faces, areas) if area > 0]
        back = [face for face, area in zip(faces, areas) if area < 0]
        if not front or not back:
            fail(f"{label}: missing opposite blade faces")
        boundary = _blade_boundary(front, label)
        opposite = _blade_boundary(back, label)
        _validate_patch_outline(boundary, front, label)
        _validate_patch_outline(opposite, back, label)
        if boundary != {(end, start) for start, end in opposite}:
            fail(f"{label}: opposite blade coverage differs")
        if abs(sum(areas)) > max(1e-12, sum(abs(area) for area in areas) * 1e-7):
            fail(f"{label}: opposite blade areas differ")


def _blade_components(vertices, indices, blade_ids, tolerance, label):
    components = {}
    if len(indices) > BLADE_MAX_COUNT * BLADE_MAX_TRIANGLES * 3:
        fail(f"{label}: whole-blade triangle limit exceeded")
    for offset, blade_id in enumerate(blade_ids):
        component = components.setdefault(blade_id, [])
        component.extend(indices[offset * 3:offset * 3 + 3])
        if len(component) > BLADE_MAX_TRIANGLES * 3 or len(components) > BLADE_MAX_COUNT:
            fail(f"{label}: whole-blade component limit exceeded")
    if len(components) < 2:
        fail(f"{label}: whole-blade reduction requires at least two blades")
    descriptors = {}
    for blade_id in sorted(components):
        selected = components[blade_id]
        blade_label = f"{label}: blade {blade_id}"
        validate_ground(vertices, selected, tolerance, blade_label)
        points = sorted({tuple(vertices[index][:3]) for index in selected})
        if max(point[2] for point in points) <= tolerance:
            fail(f"{blade_label}: zero-height blade")
        if any(abs(vertices[index][SCALAR] - 1.5) > 1e-6 for index in selected):
            fail(f"{blade_label}: expected grass scalar")
        triangles = [tuple(tuple(vertices[selected[offset + corner]][:3])
                           for corner in range(3)) for offset in range(0, len(selected), 3)]
        _validate_blade_faces(triangles, blade_label)
        roots = [point for point in points if abs(point[2]) <= tolerance]
        descriptors[blade_id] = (sum(point[0] for point in roots) / len(roots),
                                sum(point[1] for point in roots) / len(roots),
                                max(point[2] for point in points),
                                math.hypot(max(point[0] for point in roots) -
                                           min(point[0] for point in roots),
                                           max(point[1] for point in roots) -
                                           min(point[1] for point in roots)))
    return components, descriptors


def _select_blades(components, descriptors, target):
    ids = sorted(components)
    dimensions = len(descriptors[ids[0]])
    minimum = [min(descriptors[key][axis] for key in ids) for axis in range(dimensions)]
    spans = [max(max(descriptors[key][axis] for key in ids) - minimum[axis], 1e-9)
             for axis in range(dimensions)]
    normalized = {key: tuple((descriptors[key][axis] - minimum[axis]) / spans[axis]
                            for axis in range(dimensions)) for key in ids}
    first = max(ids, key=lambda key: (normalized[key][2] +
                sum((normalized[key][axis] - 0.5) ** 2 for axis in range(2)), -key))
    order = [first]
    remaining = [key for key in ids if key != first]
    distances = {key: float("inf") for key in remaining}
    while remaining:
        latest = normalized[order[-1]]
        for key in remaining:
            distance = sum((normalized[key][axis] - latest[axis]) ** 2
                           for axis in range(dimensions))
            distances[key] = min(distances[key], distance)
        chosen = max(remaining, key=lambda key: (distances[key], -key))
        order.append(chosen)
        remaining.remove(chosen)
    cost = 0
    candidates = []
    for count, key in enumerate(order[:-1], 1):
        cost += len(components[key])
        candidates.append((abs(cost - target), cost, count))
    count = min(candidates)[2]
    return order[:count]


def _omitted_blade_error(vertices, components, selected):
    representatives = []
    for key in selected:
        points = sorted({tuple(vertices[index][:3]) for index in components[key]})
        representatives.extend((min(points, key=lambda point: (point[2], point)),
                                max(points, key=lambda point: (point[2], point))))
    error = 0.0
    for key in sorted(components):
        if key in selected:
            continue
        points = [vertices[index][:3] for index in components[key]]
        center = tuple(math.fsum(point[axis] for point in points) / len(points)
                       for axis in range(3))
        representative = min(representatives, key=lambda point:
                             (sum((point[axis] - center[axis]) ** 2 for axis in range(3)), point))
        error = max(error, max(math.dist(point, representative) for point in points))
    if not math.isfinite(error):
        fail("whole-blade reduction produced nonfinite error")
    return max(error, CLUSTER_ERROR_STEP)


def _build_blade_chain(vertices, indices, blade_ids, tolerance, label):
    components, descriptors = _blade_components(vertices, indices, blade_ids, tolerance, label)
    selected = _select_blades(components, descriptors,
                             len(indices) * LOD_POLICIES["grass_blades_2"][1])
    coarse_indices = [index for key in sorted(selected) for index in components[key]]
    if not 0 < len(coarse_indices) < len(indices):
        fail(f"{label}: whole-blade target cannot produce a cheaper level")
    base_vertices, base_indices = optimize(vertices, indices)
    reduced, reduced_indices = optimize(vertices, coarse_indices)
    validate_ground(reduced, reduced_indices, tolerance, f"{label}: whole-blade level 1")
    validate_mesh(reduced, reduced_indices, f"{label}: whole-blade level 1")
    expected = sorted(tuple(vertices[index] for index in coarse_indices[offset:offset + 3])
                      for offset in range(0, len(coarse_indices), 3))
    actual = sorted(tuple(reduced[index] for index in reduced_indices[offset:offset + 3])
                    for offset in range(0, len(reduced_indices), 3))
    if expected != actual:
        fail(f"{label}: optimization changed whole-blade geometry or attributes")
    error = _omitted_blade_error(vertices, components, selected)
    return [Lod(base_vertices, base_indices, 0.0, LOD_SCREEN_BASE),
            Lod(reduced, reduced_indices, error, LOD_SCREEN_BASE / LOD_SCREEN_FALLOFF)]


def validate_ground(vertices, indices, tolerance, label):
    if not math.isfinite(tolerance) or tolerance < 0:
        fail(f"{label}: ground tolerance must be finite and nonnegative")
    if not indices:
        fail(f"{label}: grounded geometry is empty")
    minimum = min(vertices[index][2] for index in indices)
    if abs(minimum) > tolerance:
        fail(f"{label}: grounded geometry has minimum Z {minimum}")


def validate_cook_constraints(vertices, indices, grounded, ground_tolerance, blade_ids, label,
                              policy="none"):
    if not math.isfinite(ground_tolerance) or ground_tolerance < 0:
        fail(f"{label}: ground tolerance must be finite and nonnegative")
    if blade_ids is not None:
        if not isinstance(blade_ids, (list, tuple)):
            fail(f"{label}: blade IDs must be a list or tuple")
        if len(blade_ids) != len(indices) // 3 or any(
            type(blade_id) is not int or blade_id < 0 for blade_id in blade_ids
        ):
            fail(f"{label}: blade IDs must be nonnegative integers, one per triangle")
        if policy != "grass_blades_2":
            fail(f"{label}: blade metadata requires a whole-blade policy")
    elif policy == "grass_blades_2":
        fail(f"{label}: whole-blade policy requires blade IDs")
    if grounded:
        validate_ground(vertices, indices, ground_tolerance, label)


def build_lod_chain(vertices, indices, policy, label, *, grounded=False,
                    ground_tolerance=0.0001, blade_ids=None):
    """Produce the LOD chain a policy asks for.

    Level 0 is the cleaned source at whatever density it arrived with. Coarser
    levels are quadric simplifications of it, each with a strictly larger error
    and a strictly smaller screen threshold - the decoder rejects anything else,
    because equal values would let two levels qualify at one distance.
    """
    ratios = LOD_POLICIES.get(policy)
    if ratios is None:
        fail(f"{label}: unknown LOD policy {policy!r}")
    if len(ratios) > MAX_MESH_LODS:
        fail(f"{label}: policy {policy!r} exceeds {MAX_MESH_LODS} levels")
    validate_mesh(vertices, indices, label)
    validate_cook_constraints(vertices, indices, grounded, ground_tolerance, blade_ids, label,
                              policy)
    if policy == "grass_blades_2":
        return _build_blade_chain(vertices, indices, blade_ids, ground_tolerance, label)
    base_vertices, base_indices = optimize(vertices, indices)
    root_mask = None
    if grounded:
        root_mask = [abs(vertex[2]) <= ground_tolerance for vertex in base_vertices]
    chain = [Lod(base_vertices, base_indices, 0.0, LOD_SCREEN_BASE)]
    for level, ratio in enumerate(ratios[1:], start=1):
        target = max(3, int(len(base_indices) * ratio) // 3 * 3)
        if target >= len(chain[-1].indices):
            # Nothing left to remove at this ratio; a shorter chain is valid and
            # honest, where a duplicated level would be neither.
            break
        reduced, reduced_indices, error = simplify(
            base_vertices, base_indices, target, locked=root_mask
        )
        if not reduced_indices or len(reduced_indices) >= len(chain[-1].indices):
            break
        reduced, reduced_indices = optimize(reduced, reduced_indices)
        if grounded:
            validate_ground(reduced, reduced_indices, ground_tolerance, f"{label}: level {level}")
        error = max(error, chain[-1].error + CLUSTER_ERROR_STEP)
        threshold = LOD_SCREEN_BASE / (LOD_SCREEN_FALLOFF ** level)
        if threshold >= chain[-1].threshold:
            fail(f"{label}: level {level} threshold is not strictly decreasing")
        chain.append(Lod(reduced, reduced_indices, error, threshold))
    return chain


# -- cluster DAG --------------------------------------------------------------


class Cluster:
    __slots__ = ("first_index", "index_count", "center", "radius", "error",
                 "parent_error", "group", "level")

    def __init__(self, first_index, index_count, center, radius, error, level):
        self.first_index = first_index
        self.index_count = index_count
        self.center = center
        self.radius = radius
        self.error = error
        self.parent_error = CLUSTER_ERROR_ROOT
        self.group = CLUSTER_GROUP_NONE
        self.level = level


class Group:
    __slots__ = ("first_child", "child_count", "center", "radius", "error", "level")

    def __init__(self, first_child, child_count, center, radius, error, level):
        self.first_child = first_child
        self.child_count = child_count
        self.center = center
        self.radius = radius
        self.error = error
        self.level = level


def _morton(cell):
    result = 0
    for bit in range(10):
        for axis in range(3):
            result |= ((cell[axis] >> bit) & 1) << (bit * 3 + axis)
    return result


def _morton_order(vertices, indices):
    """Z-order over triangle centroids. Weaker than a graph partitioner, but it
    has no dependency, no tuning, and is deterministic - which the cook step's
    byte-for-byte reproducibility needs."""
    minimum, maximum = bounds_of(vertices)
    extent = [max(maximum[axis] - minimum[axis], 0.0) for axis in range(3)]
    keys = []
    for triangle in range(len(indices) // 3):
        centroid = [0.0, 0.0, 0.0]
        for corner in range(3):
            position = vertices[indices[triangle * 3 + corner]][POSITION]
            for axis in range(3):
                centroid[axis] += position[axis] / 3.0
        cell = []
        for axis in range(3):
            span = extent[axis]
            value = 0.0 if span <= 0 else (centroid[axis] - minimum[axis]) / span
            cell.append(int(round(min(max(value, 0.0), 1.0) * 1023)))
        keys.append((_morton(cell), triangle))
    keys.sort()
    ordered = []
    for _, triangle in keys:
        ordered.extend(indices[triangle * 3 : triangle * 3 + 3])
    return ordered


def _sphere(vertices, indices, first, count):
    points = [vertices[indices[first + step]][POSITION] for step in range(count)]
    minimum = [min(point[axis] for point in points) for axis in range(3)]
    maximum = [max(point[axis] for point in points) for axis in range(3)]
    center = tuple((minimum[axis] + maximum[axis]) * 0.5 for axis in range(3))
    radius = 0.0
    for point in points:
        radius = max(
            radius,
            math.sqrt(sum((point[axis] - center[axis]) ** 2 for axis in range(3))),
        )
    return center, radius


def _group_sphere(clusters, first_child, child_count):
    children = clusters[first_child : first_child + child_count]
    center = tuple(
        sum(child.center[axis] for child in children) / child_count for axis in range(3)
    )
    radius = 0.0
    for child in children:
        distance = math.sqrt(
            sum((child.center[axis] - center[axis]) ** 2 for axis in range(3))
        )
        radius = max(radius, distance + child.radius)
    return center, radius


class Dag:
    __slots__ = ("clusters", "groups", "vertices", "indices", "levels")

    def __init__(self):
        self.clusters = []
        self.groups = []
        self.vertices = []
        self.indices = []
        self.levels = []


def build_cluster_dag(vertices, indices, label, cluster_triangles=CLUSTER_MAX_TRIANGLES,
                      group_size=CLUSTER_GROUP_SIZE, ratio=0.5):
    """Cluster DAG over a single mesh. See ingot/docs/cluster-lod.md."""
    validate_mesh(vertices, indices, label)
    if not 1 <= cluster_triangles <= CLUSTER_MAX_TRIANGLES:
        fail(f"{label}: cluster size {cluster_triangles} out of range")
    if not 2 <= group_size <= 16 or not 0.0 < ratio < 1.0:
        fail(f"{label}: invalid cluster grouping configuration")
    dag = Dag()
    dag.vertices = list(vertices)
    dag.indices = _morton_order(vertices, indices)
    level_first = len(dag.clusters)
    _emit_clusters(dag, 0, len(dag.indices), 0.0, 0, cluster_triangles)
    dag.levels.append((0, len(dag.vertices), 0, len(dag.indices), 0.0))
    for level in range(1, CLUSTER_MAX_LEVELS):
        count = len(dag.clusters) - level_first
        if count <= 1:
            break
        step = _cluster_level(dag, level_first, count, level, group_size, ratio,
                              cluster_triangles)
        if step is None:
            break
        level_first = step
    return dag


def _emit_clusters(dag, first_index, index_count, error, level, cluster_triangles):
    triangles = index_count // 3
    for start in range(0, triangles, cluster_triangles):
        count = min(cluster_triangles, triangles - start)
        first = first_index + start * 3
        center, radius = _sphere(dag.vertices, dag.indices, first, count * 3)
        dag.clusters.append(Cluster(first, count * 3, center, radius, error, level))


def _cluster_level(dag, level_first, count, level, group_size, ratio, cluster_triangles):
    """One simplify-and-repartition step. Returns the new level's first cluster,
    or None when the level could not shrink and the chain must stop."""
    shared = _shared_vertices(dag, level_first, count, group_size)
    produced_first = len(dag.clusters)
    group_mark = len(dag.groups)
    vertex_mark = len(dag.vertices)
    index_mark = len(dag.indices)
    worst = 0.0
    for start in range(0, count, group_size):
        children = min(group_size, count - start)
        error = _cluster_group(dag, level_first + start, children, shared, level,
                               ratio, cluster_triangles)
        if error is None:
            _rewind(dag, produced_first, group_mark, vertex_mark, index_mark,
                    level_first, count)
            return None
        worst = max(worst, error)
    produced = len(dag.indices) - index_mark
    previous = index_mark - dag.levels[-1][2]
    if produced == 0 or produced >= previous:
        # A level that failed to shrink would repeat forever. Rewinding leaves
        # the previous level as the root set, which is still a valid DAG.
        _rewind(dag, produced_first, group_mark, vertex_mark, index_mark,
                level_first, count)
        return None
    dag.levels.append(
        (vertex_mark, len(dag.vertices) - vertex_mark, index_mark, produced, worst)
    )
    return produced_first


def _rewind(dag, cluster_mark, group_mark, vertex_mark, index_mark, level_first, count):
    """Discard a level that produced nothing usable and restore its children to
    roots. Nothing outside the DAG references the discarded work yet."""
    del dag.clusters[cluster_mark:]
    del dag.groups[group_mark:]
    del dag.vertices[vertex_mark:]
    del dag.indices[index_mark:]
    for cluster in dag.clusters[level_first : level_first + count]:
        cluster.group = CLUSTER_GROUP_NONE
        cluster.parent_error = CLUSTER_ERROR_ROOT


def _shared_vertices(dag, level_first, count, group_size):
    """Every vertex used by more than one group. Those are the positions a
    group's simplification must leave untouched."""
    owner = {}
    shared = set()
    for offset in range(count):
        cluster = dag.clusters[level_first + offset]
        group = offset // group_size
        for step in range(cluster.index_count):
            vertex = dag.indices[cluster.first_index + step]
            existing = owner.get(vertex)
            if existing is None:
                owner[vertex] = group
            elif existing != group:
                shared.add(vertex)
    return shared


def _cluster_group(dag, first_child, child_count, shared, level, ratio,
                   cluster_triangles):
    first = dag.clusters[first_child].first_index
    last = first
    for offset in range(child_count):
        cluster = dag.clusters[first_child + offset]
        if cluster.first_index != last:
            return None
        last = cluster.first_index + cluster.index_count
    remap = {}
    work_vertices = []
    work_indices = []
    locked = []
    for step in range(first, last):
        source = dag.indices[step]
        slot = remap.get(source)
        if slot is None:
            slot = len(work_vertices)
            remap[source] = slot
            work_vertices.append(dag.vertices[source])
            locked.append(source in shared)
        work_indices.append(slot)
    child_error = max(
        dag.clusters[first_child + offset].error for offset in range(child_count)
    )
    target = max(3, int(len(work_indices) * ratio) // 3 * 3)
    reduced, reduced_indices, error = simplify(work_vertices, work_indices, target, locked)
    if not reduced_indices:
        return None
    group_error = max(child_error, error)
    if group_error <= child_error:
        group_error = child_error + max(child_error, 1.0) * CLUSTER_ERROR_STEP
    group_index = len(dag.groups)
    for offset in range(child_count):
        dag.clusters[first_child + offset].group = group_index
        dag.clusters[first_child + offset].parent_error = group_error
    base = len(dag.vertices)
    dag.vertices.extend(reduced)
    index_first = len(dag.indices)
    dag.indices.extend(index + base for index in reduced_indices)
    _emit_clusters(dag, index_first, len(reduced_indices), group_error, level,
                   cluster_triangles)
    center, radius = _group_sphere(dag.clusters, first_child, child_count)
    dag.groups.append(Group(first_child, child_count, center, radius, group_error, level))
    return group_error


# -- packing and serialisation ------------------------------------------------


def _quantize(value, minimum, maximum, span):
    extent = maximum - minimum
    if extent <= 0:
        return 0
    normalized = min(max((value - minimum) / extent, 0.0), 1.0)
    return int(round(normalized * span))


def _octahedral_encode(normal):
    total = sum(abs(component) for component in normal)
    if total <= 0:
        return 0.0, 0.0
    projected = (normal[0] / total, normal[1] / total)
    if normal[2] >= 0:
        return projected
    sign_x = 1.0 if projected[0] >= 0 else -1.0
    sign_y = 1.0 if projected[1] >= 0 else -1.0
    return (1.0 - abs(projected[1])) * sign_x, (1.0 - abs(projected[0])) * sign_y


def pack_vertex(vertex, bounds, uv_bounds):
    """36 bytes to 16. See ingot/docs/cooked-mesh-v2.md for the field layout and
    the accuracy each channel gives up."""
    minimum, maximum = bounds
    uv_minimum, uv_maximum = uv_bounds
    position = tuple(
        _quantize(vertex[axis], minimum[axis], maximum[axis], PACKED_POSITION_RANGE)
        for axis in range(3)
    )
    encoded = _octahedral_encode(vertex[NORMAL])
    normal = tuple(
        int(round(min(max(value, -1.0), 1.0) * PACKED_NORMAL_RANGE)) for value in encoded
    )
    uv = tuple(
        _quantize(vertex[7 + axis], uv_minimum[axis], uv_maximum[axis], PACKED_UV_RANGE)
        for axis in range(2)
    )
    scalar_ratio = min(max(vertex[SCALAR], 0.0), PACKED_SCALAR_MAX) / PACKED_SCALAR_MAX
    scalar = int(round(scalar_ratio * PACKED_SCALAR_RANGE))
    return struct.pack(
        "<HHHbbHHBBBB", *position, normal[0], normal[1], uv[0], uv[1], scalar, 0, 0, 0
    )


class CookedMesh:
    __slots__ = ("id", "lods", "dag", "bounds", "uv_bounds")

    def __init__(self, mesh_id, lods, dag=None):
        self.id = mesh_id
        self.lods = lods
        self.dag = dag
        vertices = [vertex for lod in lods for vertex in lod.vertices]
        if dag is not None:
            vertices = list(dag.vertices)
        self.bounds = bounds_of(vertices)
        self.uv_bounds = uv_bounds_of(vertices)


def cook_mesh(mesh_id, vertices, indices, policy="none", clustered=False, label=None, *,
              grounded=False, ground_tolerance=0.0001, blade_ids=None):
    """Turn one source mesh into a cooked chain, optionally with a cluster DAG.

    A DAG and a discrete chain are alternatives, not companions: the DAG already
    carries every level's geometry, so cooking both would store the same
    triangles twice.
    """
    label = label or f"mesh {mesh_id}"
    validate_mesh(vertices, indices, label)
    validate_cook_constraints(vertices, indices, grounded, ground_tolerance, blade_ids, label,
                              policy)
    if clustered:
        if policy == "grass_blades_2":
            fail(f"{label}: whole-blade policy does not support clustered cooking")
        dag = build_cluster_dag(vertices, indices, label)
        lods = []
        for first_vertex, vertex_count, first_index, index_count, error in dag.levels:
            level = len(lods)
            threshold = LOD_SCREEN_BASE / (LOD_SCREEN_FALLOFF ** level)
            # A level's indices are stored relative to its own vertex span, the
            # same way version 1 stores them relative to a mesh. The DAG keeps
            # them mesh-global so cluster spans can be, so rebase here.
            local = [
                index - first_vertex
                for index in dag.indices[first_index : first_index + index_count]
            ]
            if any(not 0 <= index < vertex_count for index in local):
                fail(f"{label}: level {level} references another level's vertices")
            lods.append(
                Lod(
                    dag.vertices[first_vertex : first_vertex + vertex_count],
                    local,
                    error,
                    threshold,
                )
            )
        _force_monotonic(lods, label)
        if grounded:
            for level, lod in enumerate(lods):
                validate_ground(lod.vertices, lod.indices, ground_tolerance,
                                f"{label}: clustered level {level}")
        return CookedMesh(mesh_id, lods, dag)
    return CookedMesh(mesh_id, build_lod_chain(
        vertices, indices, policy, label, grounded=grounded,
        ground_tolerance=ground_tolerance, blade_ids=blade_ids
    ))


def _force_monotonic(lods, label):
    if not lods:
        fail(f"{label}: cooked mesh has no levels")
    lods[0].error = 0.0
    for level in range(1, len(lods)):
        if lods[level].error <= lods[level - 1].error:
            lods[level].error = lods[level - 1].error + CLUSTER_ERROR_STEP
        if lods[level].threshold >= lods[level - 1].threshold:
            fail(f"{label}: level {level} threshold is not strictly decreasing")


def serialize(meshes, packed=True):
    """Assemble an INGMESH2 bundle. Mirrors the layout the Odin decoder walks."""
    if not meshes or len(meshes) > MAX_MESHES:
        fail(f"mesh count {len(meshes)} outside 1..{MAX_MESHES}")
    meshes = sorted(meshes, key=lambda mesh: mesh.id)
    if len({mesh.id for mesh in meshes}) != len(meshes) or meshes[0].id <= 0:
        fail("mesh ids must be unique and non-zero")
    lod_count = sum(len(mesh.lods) for mesh in meshes)
    cluster_count = sum(len(mesh.dag.clusters) if mesh.dag else 0 for mesh in meshes)
    group_count = sum(len(mesh.dag.groups) if mesh.dag else 0 for mesh in meshes)
    vertex_count = sum(len(lod.vertices) for mesh in meshes for lod in mesh.lods)
    index_count = sum(len(lod.indices) for mesh in meshes for lod in mesh.lods)
    flags = FLAG_PACKED_VERTICES if packed else 0
    if cluster_count:
        flags |= FLAG_CLUSTERS
    header = struct.pack(
        "<8sIIIIIIIIII",
        MAGIC,
        VERSION,
        len(meshes),
        lod_count,
        cluster_count,
        group_count,
        vertex_count,
        index_count,
        flags,
        0,
        0,
    )
    parts = _serialize_tables(meshes, packed)
    data = header + b"".join(parts)
    if len(data) > MAX_BYTES:
        fail(f"bundle is {len(data)} bytes, over the {MAX_BYTES} limit")
    return data


def _serialize_tables(meshes, packed):
    records = bytearray()
    lods = bytearray()
    clusters = bytearray()
    groups = bytearray()
    vertices = bytearray()
    indices = bytearray()
    lod_first = cluster_first = group_first = 0
    vertex_first = index_first = 0
    for mesh in meshes:
        mesh_clusters = len(mesh.dag.clusters) if mesh.dag else 0
        mesh_groups = len(mesh.dag.groups) if mesh.dag else 0
        records.extend(
            struct.pack(
                "<IIIIIIIffffffffff",
                mesh.id,
                lod_first,
                len(mesh.lods),
                cluster_first,
                mesh_clusters,
                group_first,
                mesh_groups,
                *mesh.bounds[0],
                *mesh.bounds[1],
                *mesh.uv_bounds[0],
                *mesh.uv_bounds[1],
            )
        )
        base_index = index_first
        for lod in mesh.lods:
            lods.extend(
                struct.pack(
                    "<IIIIff",
                    vertex_first,
                    len(lod.vertices),
                    index_first,
                    len(lod.indices),
                    lod.error,
                    lod.threshold,
                )
            )
            for vertex in lod.vertices:
                if packed:
                    vertices.extend(pack_vertex(vertex, mesh.bounds, mesh.uv_bounds))
                else:
                    vertices.extend(struct.pack("<fffffffff", *vertex))
            # Indices are stored local to their level, exactly as version 1
            # stores them local to their mesh.
            for index in lod.indices:
                indices.extend(struct.pack("<I", index))
            vertex_first += len(lod.vertices)
            index_first += len(lod.indices)
        if mesh.dag:
            _serialize_dag(mesh.dag, clusters, groups, base_index)
        lod_first += len(mesh.lods)
        cluster_first += mesh_clusters
        group_first += mesh_groups
    return [records, lods, clusters, groups, vertices, indices]


def _serialize_dag(dag, clusters, groups, base_index):
    for cluster in dag.clusters:
        clusters.extend(
            struct.pack(
                "<IIffffffII",
                cluster.first_index + base_index,
                cluster.index_count,
                *cluster.center,
                cluster.radius,
                cluster.error,
                cluster.parent_error,
                cluster.group,
                cluster.level,
            )
        )
    for group in dag.groups:
        groups.extend(
            struct.pack(
                "<IIfffffI",
                group.first_child,
                group.child_count,
                *group.center,
                group.radius,
                group.error,
                group.level,
            )
        )


def write_bundle(path, data, check=False):
    """Atomic write, with the `--check` mode the existing exporter relies on."""
    if check:
        try:
            with open(path, "rb") as existing:
                current = existing.read()
        except OSError as error:
            fail(f"cannot read cooked output for --check: {error}")
        if current != data:
            fail(f"{path} is stale; regenerate it without --check")
        return
    directory = os.path.dirname(os.path.abspath(path))
    os.makedirs(directory, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=".ingmesh-", dir=directory)
    try:
        with os.fdopen(descriptor, "wb") as output:
            output.write(data)
        os.replace(temporary, path)
    except BaseException:
        if os.path.exists(temporary):
            os.unlink(temporary)
        raise

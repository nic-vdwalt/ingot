"""Tests for `mesh_cook`.

Run with `python3 -m unittest discover ingot/tools` or directly. No Blender and
no third-party packages are required: the module under test is deliberately
dependency-free so it can run inside Blender's bundled interpreter, and the
tests keep that property honest.
"""

import math
import os
import struct
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import mesh_cook as cook


def grid(cells, ripple=0.0):
    """A `cells` x `cells` quad grid on the XY plane, optionally rippled.

    A flat grid is the sharpest oracle for a quadric simplifier: every interior
    collapse is exactly free, so a reported error above the arithmetic floor is
    a bug in the metric rather than a property of the mesh.
    """
    edge = cells + 1
    vertices = []
    for row in range(edge):
        for column in range(edge):
            height = math.sin(column * 0.4) * ripple
            vertices.append(
                (
                    float(column),
                    float(row),
                    height,
                    0.0,
                    0.0,
                    1.0,
                    0.0,
                    column / cells,
                    row / cells,
                )
            )
    indices = []
    for row in range(cells):
        for column in range(cells):
            base = row * edge + column
            indices += [base, base + 1, base + edge]
            indices += [base + 1, base + edge + 1, base + edge]
    return vertices, indices


def acmr(indices, cache_size=cook.CACHE_SIZE):
    """Average cache misses per triangle under the modelled cache.

    The absolute value depends on the cache size; only the direction of the
    change matters to the tests that use it.
    """
    cache = []
    misses = 0
    for index in indices:
        if index in cache:
            continue
        misses += 1
        cache.insert(0, index)
        del cache[cache_size:]
    return misses / (len(indices) / 3)


# The contract between this module and `ingot/procgen/mesh_optimize.odin`,
# written out literally on both sides. A 4x4 grid is small enough to read and
# large enough that all three passes do real work: 32 triangles fill the
# modelled cache and force evictions, and the run split produces more than one
# run to sort.
#
# If either implementation changes, the other's test fails. That is the whole
# point of pinning it - the two cooks cannot call each other, so nothing else
# would notice them drifting apart until an asset shipped in two different index
# orders depending on which tool built it.
#
# Regenerate with:
#
#   python3 -c "import test_mesh_cook as t, mesh_cook as c; \
#       v, i = t.grid(4); print(c.optimize(v, i)[1])"
GOLDEN_CELLS = 4

GOLDEN_INDICES = [
    0, 1, 2, 0, 3, 1, 2, 4, 5, 1, 6, 4,
    4, 6, 7, 1, 8, 6, 9, 2, 10, 9, 0, 2,
    10, 2, 5, 3, 11, 8, 3, 8, 1, 11, 12, 8,
    6, 13, 7, 8, 12, 14, 8, 14, 6, 15, 9, 10,
    16, 0, 9, 16, 17, 0, 6, 14, 13, 12, 18, 14,
    14, 19, 13, 2, 1, 4, 5, 4, 20, 4, 7, 20,
    17, 3, 0, 17, 21, 3, 21, 11, 3, 22, 23, 15,
    23, 9, 15, 23, 16, 9, 14, 18, 19, 18, 24, 19,
]

# Where each output vertex came from in the source. Pinning this as well as the
# index order catches a fetch pass that renumbered consistently but chose a
# different first-use walk.
GOLDEN_SOURCE = [
    7, 12, 11, 8, 16, 15, 17, 21, 13, 6, 10, 9, 14,
    22, 18, 5, 2, 3, 19, 23, 20, 4, 0, 1, 24,
]


class OptimizeTest(unittest.TestCase):
    def test_matches_the_runtime_golden_order(self):
        vertices, indices = grid(GOLDEN_CELLS)
        result_vertices, result_indices = cook.optimize(vertices, indices)
        self.assertEqual(result_indices, GOLDEN_INDICES)
        self.assertEqual(
            [vertices.index(vertex) for vertex in result_vertices], GOLDEN_SOURCE
        )

    def test_optimization_is_a_permutation(self):
        vertices, indices = grid(8)
        result_vertices, result_indices = cook.optimize(vertices, indices)
        self.assertEqual(len(result_indices), len(indices))
        self.assertLessEqual(len(result_vertices), len(vertices))
        before = sorted(
            tuple(sorted(indices[triangle * 3 : triangle * 3 + 3]))
            for triangle in range(len(indices) // 3)
        )
        after = sorted(
            tuple(
                sorted(
                    vertices.index(result_vertices[result_indices[triangle * 3 + corner]])
                    for corner in range(3)
                )
            )
            for triangle in range(len(result_indices) // 3)
        )
        self.assertEqual(before, after)

    def test_vertex_fetch_renumbers_into_first_use_order(self):
        vertices = [(float(index),) + (0.0,) * 8 for index in range(4)]
        result_vertices, result_indices = cook.optimize_vertex_fetch(
            vertices, [3, 1, 2, 3, 2, 0]
        )
        self.assertEqual(result_indices[:3], [0, 1, 2])
        self.assertEqual(result_vertices[0][0], 3.0)
        self.assertEqual(len(result_vertices), 4)

    def test_cache_pass_lowers_average_cache_misses(self):
        vertices, indices = grid(16)
        reordered = cook.optimize_vertex_cache(indices, len(vertices))
        after = acmr(reordered)
        self.assertLess(after, acmr(indices))
        self.assertLess(after, 1.0)

    def test_optimization_is_deterministic(self):
        vertices, indices = grid(12)
        first = cook.optimize(vertices, indices)
        second = cook.optimize(vertices, indices)
        self.assertEqual(first[1], second[1])

    def test_a_lone_triangle_passes_through(self):
        vertices = [(float(index),) + (0.0,) * 8 for index in range(3)]
        self.assertEqual(cook.optimize_vertex_cache([2, 0, 1], 3), [2, 0, 1])
        self.assertEqual(cook.optimize_overdraw(vertices, [2, 0, 1]), [2, 0, 1])


class SimplifyTest(unittest.TestCase):
    def test_plane_simplifies_without_error(self):
        vertices, indices = grid(12)
        _, reduced, error = cook.simplify(vertices, indices, len(indices) // 2)
        self.assertLessEqual(len(reduced), len(indices) // 2)
        self.assertLess(error, 1.0e-3)

    def test_locked_positions_survive_bit_identically(self):
        cells = 12
        edge = cells + 1
        vertices, indices = grid(cells)
        locked = [
            row in (0, edge - 1) or column in (0, edge - 1)
            for row in range(edge)
            for column in range(edge)
        ]
        reduced, reduced_indices, _ = cook.simplify(vertices, indices, 6, locked)
        self.assertTrue(reduced_indices)
        survivors = {vertex[cook.POSITION] for vertex in reduced}
        for index, is_locked in enumerate(locked):
            if not is_locked:
                continue
            self.assertIn(vertices[index][cook.POSITION], survivors)

    def test_error_is_a_distance_not_a_weight(self):
        # Boundary planes carry a thousand times a face's weight. Without the
        # normalisation the reported error would scale with how much boundary a
        # region happened to contain rather than with how far the surface moved.
        vertices, indices = grid(16, ripple=0.25)
        _, _, error = cook.simplify(vertices, indices, len(indices) // 4)
        self.assertGreater(error, 0.0)
        self.assertLess(error, 1.0)

    def test_simplify_is_deterministic(self):
        vertices, indices = grid(10, ripple=0.2)
        first = cook.simplify(vertices, indices, len(indices) // 4)
        second = cook.simplify(vertices, indices, len(indices) // 4)
        self.assertEqual(first[1], second[1])
        self.assertEqual(first[2], second[2])


class LodChainTest(unittest.TestCase):
    def test_grounded_chain_preserves_all_root_positions(self):
        vertices, indices = grid(12)
        vertices = [(vertex[0], 0.0, vertex[1]) + vertex[3:] for vertex in vertices]
        roots = {vertex[:3] for vertex in vertices if vertex[2] == 0}
        chain = cook.build_lod_chain(vertices, indices, "tree_4", "rooted", grounded=True)
        self.assertGreater(len(chain), 1)
        for lod in chain:
            referenced = {lod.vertices[index][:3] for index in lod.indices}
            self.assertTrue(roots <= referenced)
            self.assertEqual(min(position[2] for position in referenced), 0)
        first = cook.cook_mesh(1, vertices, indices, "tree_4", grounded=True)
        second = cook.cook_mesh(1, vertices, indices, "tree_4", grounded=True)
        self.assertEqual(cook.serialize([first]), cook.serialize([second]))

    def test_grounded_split_corner_attributes_keep_root_positions(self):
        vertices, indices = grid(8)
        corners = []
        for corner, index in enumerate(indices):
            source = vertices[index]
            corners.append((source[0], 0.0, source[1], 0.0,
                            1.0 if corner % 2 else -1.0, 0.0,
                            source[6], float(corner % 3), float(corner % 2)))
        roots = {vertex[:3] for vertex in corners if vertex[2] == 0}
        chain = cook.build_lod_chain(corners, list(range(len(corners))),
                                    "tree_4", "split roots", grounded=True)
        self.assertGreater(len(chain), 1)
        for lod in chain:
            self.assertTrue(roots <= {lod.vertices[index][:3] for index in lod.indices})

    def test_grounded_roots_survive_packed_and_unpacked_storage(self):
        vertices, indices = grid(12)
        vertices = [(vertex[0], 0.0, vertex[1]) + vertex[3:] for vertex in vertices]
        mesh = cook.cook_mesh(1, vertices, indices, "tree_4", grounded=True)
        for packed in (False, True):
            data = cook.serialize([mesh], packed=packed)
            header = struct.unpack_from("<8s10I", data)
            self.assertEqual(header[:3], (cook.MAGIC, cook.VERSION, 1))
            vertex_start = cook.HEADER_SIZE + cook.RECORD_SIZE + header[3] * cook.LOD_SIZE
            stride = 16 if packed else 36
            for level in range(header[3]):
                offset = cook.HEADER_SIZE + cook.RECORD_SIZE + level * cook.LOD_SIZE
                first, count, _, _, _, _ = struct.unpack_from("<4I2f", data, offset)
                heights = []
                for index in range(first, first + count):
                    address = vertex_start + index * stride
                    if packed:
                        quantized = struct.unpack_from("<3H", data, address)[2]
                        minimum, maximum = mesh.bounds
                        height = minimum[2] + quantized / 65535 * (maximum[2] - minimum[2])
                    else:
                        height = struct.unpack_from("<3f", data, address)[2]
                    heights.append(height)
                self.assertEqual(min(heights), 0.0)

    def test_grounded_rejects_floating_and_invalid_tolerances(self):
        vertices, indices = grid(4)
        floating = [vertex[:2] + (1.0,) + vertex[3:] for vertex in vertices]
        with self.assertRaisesRegex(cook.CookError, "minimum Z"):
            cook.cook_mesh(1, floating, indices, grounded=True)
        for tolerance in (-1, float("nan"), float("inf")):
            with self.assertRaisesRegex(cook.CookError, "tolerance"):
                cook.build_lod_chain(vertices, indices, "none", "test",
                                     ground_tolerance=tolerance)

    def test_grounding_uses_referenced_vertices_and_tolerance(self):
        vertices, indices = grid(4)
        floating = [vertex[:2] + (0.5,) + vertex[3:] for vertex in vertices]
        floating.append(vertices[0])
        with self.assertRaisesRegex(cook.CookError, "minimum Z"):
            cook.build_lod_chain(floating, indices, "none", "unused root", grounded=True)
        for height in (-0.00005, 0.00005):
            shifted = [vertex[:2] + (height,) + vertex[3:] for vertex in vertices]
            mesh = cook.cook_mesh(1, shifted, indices, grounded=True)
            self.assertEqual(min(vertex[2] for vertex in mesh.lods[0].vertices), height)
        below = [vertex[:2] + (-0.5,) + vertex[3:] for vertex in vertices]
        with self.assertRaisesRegex(cook.CookError, "minimum Z"):
            cook.cook_mesh(1, below, indices, grounded=True)

    def test_grounded_unreducible_surface_keeps_single_level(self):
        vertices, indices = grid(4)
        chain = cook.build_lod_chain(vertices, indices, "tree_4", "flat", grounded=True)
        self.assertEqual(len(chain), 1)
        self.assertEqual(len(chain[0].indices), len(indices))

    def test_grounded_cluster_levels_are_validated(self):
        vertices, indices = grid(12)
        mesh = cook.cook_mesh(1, vertices, indices, clustered=True, grounded=True)
        for lod in mesh.lods:
            self.assertEqual(min(lod.vertices[index][2] for index in lod.indices), 0)

    def test_grounded_rejects_detached_cluster_level(self):
        vertices, indices = grid(12)
        dag = cook.build_cluster_dag(vertices, indices, "fixture")
        first_vertex, vertex_count, _, _, _ = dag.levels[-1]
        for index in range(first_vertex, first_vertex + vertex_count):
            vertex = dag.vertices[index]
            dag.vertices[index] = vertex[:2] + (1.0,) + vertex[3:]
        with mock.patch.object(cook, "build_cluster_dag", return_value=dag):
            with self.assertRaisesRegex(cook.CookError, "clustered level.*minimum Z"):
                cook.cook_mesh(1, vertices, indices, clustered=True, grounded=True)

    def test_grounded_rejects_detached_discrete_result(self):
        vertices, indices = grid(4)
        floating = [vertex[:2] + (1.0,) + vertex[3:] for vertex in vertices]
        with mock.patch.object(cook, "simplify", return_value=(floating, indices[:3], 0)):
            with self.assertRaisesRegex(cook.CookError, "level 1.*minimum Z"):
                cook.build_lod_chain(vertices, indices, "tree_4", "fixture", grounded=True)

    def test_explicit_default_constraints_preserve_legacy_bytes(self):
        vertices, indices = grid(8, ripple=0.2)
        legacy = cook.cook_mesh(1, vertices, indices, "tree_4")
        explicit = cook.cook_mesh(1, vertices, indices, "tree_4", grounded=False,
                                  ground_tolerance=0.0001, blade_ids=None)
        for packed in (False, True):
            self.assertEqual(cook.serialize([legacy], packed=packed),
                             cook.serialize([explicit], packed=packed))

    def test_unrecognized_blade_metadata_is_rejected(self):
        vertices, indices = grid(4)
        for blade_ids in ([0], [True] * (len(indices) // 3), [-1] * (len(indices) // 3)):
            with self.assertRaisesRegex(cook.CookError, "blade IDs"):
                cook.cook_mesh(1, vertices, indices, blade_ids=blade_ids)
        with self.assertRaisesRegex(cook.CookError, "whole-blade policy"):
            cook.cook_mesh(1, vertices, indices, blade_ids=[0] * (len(indices) // 3))

    def test_chain_is_strictly_monotonic(self):
        vertices, indices = grid(24, ripple=0.3)
        chain = cook.build_lod_chain(vertices, indices, "tree_4", "test")
        self.assertGreater(len(chain), 1)
        for level in range(1, len(chain)):
            self.assertGreater(chain[level].error, chain[level - 1].error)
            self.assertLess(chain[level].threshold, chain[level - 1].threshold)
            self.assertLess(
                len(chain[level].indices), len(chain[level - 1].indices)
            )

    def test_level_zero_keeps_the_full_source(self):
        # The old pipeline decimated to a fixed face count before cooking and
        # lost the detail permanently. LOD 0 must be the cleaned source.
        vertices, indices = grid(20, ripple=0.3)
        chain = cook.build_lod_chain(vertices, indices, "tree_4", "test")
        self.assertEqual(len(chain[0].indices), len(indices))
        self.assertEqual(chain[0].error, 0.0)

    def test_unknown_policy_is_rejected(self):
        vertices, indices = grid(4)
        with self.assertRaises(cook.CookError):
            cook.build_lod_chain(vertices, indices, "nonexistent", "test")


class ClusterTest(unittest.TestCase):
    def test_dag_converges_and_stays_monotonic(self):
        vertices, indices = grid(32, ripple=0.3)
        dag = cook.build_cluster_dag(vertices, indices, "test")
        self.assertGreater(len(dag.levels), 1)
        self.assertGreater(len(dag.groups), 0)
        for cluster in dag.clusters:
            self.assertGreater(cluster.parent_error, cluster.error)
            self.assertLessEqual(cluster.index_count, cook.CLUSTER_MAX_TRIANGLES * 3)
        for level in range(1, len(dag.levels)):
            self.assertLess(dag.levels[level][3], dag.levels[level - 1][3])

    def test_group_borders_are_bit_identical_across_levels(self):
        # The crack test. Sharing is recomputed from the finished DAG so this is
        # an independent oracle, not a restatement of the builder.
        vertices, indices = grid(32, ripple=0.3)
        dag = cook.build_cluster_dag(vertices, indices, "test")
        owner = {}
        border = set()
        for cluster in dag.clusters:
            if cluster.level != 0:
                continue
            for step in range(cluster.index_count):
                vertex = dag.indices[cluster.first_index + step]
                existing = owner.get(vertex)
                if existing is None:
                    owner[vertex] = cluster.group
                elif existing != cluster.group:
                    border.add(vertex)
        self.assertGreater(len(border), 0)
        first_vertex, vertex_count = dag.levels[1][0], dag.levels[1][1]
        parent = {
            dag.vertices[first_vertex + offset][cook.POSITION]
            for offset in range(vertex_count)
        }
        for vertex in border:
            self.assertIn(dag.vertices[vertex][cook.POSITION], parent)

    def test_every_group_has_at_least_one_child(self):
        vertices, indices = grid(24, ripple=0.2)
        dag = cook.build_cluster_dag(vertices, indices, "test")
        for index, group in enumerate(dag.groups):
            self.assertGreater(group.child_count, 0)
            for offset in range(group.child_count):
                child = dag.clusters[group.first_child + offset]
                self.assertEqual(child.group, index)
                self.assertEqual(child.level + 1, group.level)
                self.assertEqual(child.parent_error, group.error)


def blade_fixture(count=8, alternate=True):
    vertices, indices, ids = [], [], []
    for blade in range(count):
        base = blade * 0.17
        height = 0.7 + blade * 0.08
        points = [(base, 0.0, 0.0), (base + 0.1, 0.0, 0.0),
                  (base + 0.08, 0.0, height), (base + 0.03, 0.0, height)]
        triangles = [(0, 1, 2), (0, 2, 3)]
        triangles += [(3, 2, 1), (3, 1, 0)] if alternate else [(2, 1, 0), (3, 2, 0)]
        for face, triangle in enumerate(triangles):
            for corner in triangle:
                indices.append(len(vertices))
                vertices.append(points[corner] + (0.0, -1.0 if face < 2 else 1.0,
                                0.0, 1.5, float(corner % 2), float(face % 2)))
            ids.append(blade)
    return vertices, indices, ids


class WholeBladeTest(unittest.TestCase):
    def test_complete_blades_and_opposite_diagonals(self):
        for alternate in (False, True):
            vertices, indices, ids = blade_fixture(alternate=alternate)
            mesh = cook.cook_mesh(4, vertices, indices, "grass_blades_2", blade_ids=ids)
            self.assertEqual([len(lod.indices) for lod in mesh.lods], [96, 24])
            self.assertGreater(mesh.lods[1].error, 0)
            self.assertLess(mesh.lods[1].threshold, mesh.lods[0].threshold)
            self.assertTrue(set(mesh.lods[1].vertices) <= set(vertices))
            for blade in range(8):
                source = {vertices[index] for index in indices[blade * 12:blade * 12 + 12]}
                present = source & set(mesh.lods[1].vertices)
                self.assertTrue(not present or present == source)
            repeated = cook.cook_mesh(4, vertices, indices, "grass_blades_2", blade_ids=ids)
            for packed in (False, True):
                self.assertEqual(cook.serialize([mesh], packed=packed),
                                 cook.serialize([repeated], packed=packed))

    def test_missing_sides_and_duplicate_faces_fail(self):
        vertices, indices, ids = blade_fixture()
        for bad_indices, bad_ids in ((indices[3:], ids[1:]),
                                     (indices + indices[:3], ids + ids[:1])):
            with self.assertRaises(cook.CookError):
                cook.build_lod_chain(vertices, bad_indices, "grass_blades_2", "bad",
                                     blade_ids=bad_ids)

    def test_invalid_metadata_and_clustered_policy_fail(self):
        vertices, indices, ids = blade_fixture()
        for metadata in (None, 1, iter(ids), {}, ids[:-1], [True] * len(ids), [-1] * len(ids)):
            with self.assertRaises(cook.CookError):
                cook.cook_mesh(4, vertices, indices, "grass_blades_2", blade_ids=metadata)
        with self.assertRaisesRegex(cook.CookError, "clustered"):
            cook.cook_mesh(4, vertices, indices, "grass_blades_2", clustered=True, blade_ids=ids)
        vertices, indices, ids = blade_fixture(1)
        with self.assertRaisesRegex(cook.CookError, "at least two"):
            cook.cook_mesh(4, vertices, indices, "grass_blades_2", blade_ids=ids)

    def test_floating_and_non_grass_components_fail(self):
        vertices, indices, ids = blade_fixture()
        floating = [vertex[:2] + (vertex[2] + 0.3,) + vertex[3:] for vertex in vertices]
        wrong_scalar = [vertex[:6] + (0.0,) + vertex[7:] for vertex in vertices]
        for invalid in (floating, wrong_scalar):
            with self.assertRaises(cook.CookError):
                cook.cook_mesh(4, invalid, indices, "grass_blades_2", blade_ids=ids)

    def test_touching_components_keep_independent_identity(self):
        vertices, indices, ids = blade_fixture(2)
        vertices[12:] = [vertex[:3] + vertex[3:6] + (1.5, vertex[7] + 2, vertex[8])
                         for vertex in vertices[:12]]
        mesh = cook.cook_mesh(4, vertices, indices, "grass_blades_2", blade_ids=ids)
        self.assertEqual(len(mesh.lods[1].indices), 12)
        self.assertEqual(set(mesh.lods[1].vertices), set(vertices[:12]))

    def test_unequal_costs_choose_nearest_progressive_budget(self):
        components = {0: [0] * 12, 1: [0] * 24, 2: [0] * 48}
        descriptors = {0: (0, 0, 3), 1: (1, 0, 1), 2: (0, 1, 2)}
        for target in (1, 12, 24, 50, 100):
            selected = cook._select_blades(components, descriptors, target)
            self.assertGreaterEqual(len(selected), 1)
            self.assertLess(len(selected), len(components))
            self.assertEqual(selected, cook._select_blades(components, descriptors, target))
        self.assertEqual(cook._select_blades(components, descriptors, 1), [0])

    def test_degenerate_and_zero_height_blades_fail(self):
        vertices, indices, ids = blade_fixture()
        flattened = [vertex[:2] + (0.0,) + vertex[3:] for vertex in vertices]
        with self.assertRaisesRegex(cook.CookError, "zero-height"):
            cook.cook_mesh(4, flattened, indices, "grass_blades_2", blade_ids=ids)
        indices[1] = indices[0]
        with self.assertRaisesRegex(cook.CookError, "degenerate"):
            cook.cook_mesh(4, vertices, indices, "grass_blades_2", blade_ids=ids)

    def test_segmented_blades_preserve_both_sides(self):
        vertices, indices, ids = [], [], []
        for blade in range(4):
            rings = [((blade * 0.3, 0.05 * height * height, height),
                      (blade * 0.3 + 0.1, 0.05 * height * height, height))
                     for height in (0.0, 0.4, 0.8, 1.2)]
            for segment in range(3):
                points = (rings[segment][0], rings[segment][1],
                          rings[segment + 1][1], rings[segment + 1][0])
                for triangle in ((0, 1, 2), (0, 2, 3), (3, 2, 1), (3, 1, 0)):
                    for corner in triangle:
                        indices.append(len(vertices))
                        vertices.append(points[corner] + (0.0, 1.0, 0.0, 1.5, 0.0, 0.0))
                    ids.append(blade)
        mesh = cook.cook_mesh(4, vertices, indices, "grass_blades_2", blade_ids=ids)
        self.assertEqual([len(lod.indices) for lod in mesh.lods], [144, 36])
        self.assertEqual(min(vertex[2] for vertex in mesh.lods[1].vertices), 0)
        self.assertEqual(max(vertex[2] for vertex in mesh.lods[1].vertices), 1.2)

    def test_disconnected_segments_and_crossing_boundaries_fail(self):
        first = ((0.0, 0.0, 0.0), (1.0, 0.0, 0.0), (0.0, 0.0, 1.0))
        second = tuple((point[0] + 4, point[1] + 1, point[2]) for point in first)
        with self.assertRaisesRegex(cook.CookError, "disconnected"):
            cook._validate_blade_faces([first, first[::-1], second, second[::-1]], "test")
        points = ((0.0, 0.0, 0.0), (1.0, 0.0, 1.0),
                  (0.0, 0.0, 1.0), (1.0, 0.0, 0.0))
        boundary = {(points[index], points[(index + 1) % 4]) for index in range(4)}
        with self.assertRaisesRegex(cook.CookError, "self-intersecting"):
            cook._validate_patch_outline(boundary, [first], "test")

    def test_nonmanifold_segment_junction_fails(self):
        root = (0.0, 0.0, 0.0)
        tip = (0.0, 0.0, 1.0)
        faces = []
        for point in ((1.0, 0.0, 0.5), (0.0, 1.0, 0.5), (-1.0, -1.0, 0.5)):
            triangle = (root, tip, point)
            faces.extend((triangle, triangle[::-1]))
        with self.assertRaisesRegex(cook.CookError, "nonmanifold"):
            cook._validate_blade_faces(faces, "junction")

    def test_optimization_cannot_change_retained_attributes(self):
        vertices, indices, ids = blade_fixture()
        original = cook.optimize

        def corrupt(source, selected):
            reduced, reordered = original(source, selected)
            if len(selected) < len(indices):
                vertex = reduced[0]
                reduced[0] = vertex[:7] + (vertex[7] + 0.25, vertex[8])
            return reduced, reordered

        with mock.patch.object(cook, "optimize", side_effect=corrupt):
            with self.assertRaisesRegex(cook.CookError, "changed whole-blade"):
                cook.cook_mesh(4, vertices, indices, "grass_blades_2", blade_ids=ids)

    def test_all_source_points_fit_conservative_error(self):
        vertices, indices, ids = blade_fixture()
        mesh = cook.cook_mesh(4, vertices, indices, "grass_blades_2", blade_ids=ids)
        retained = [vertex[:3] for vertex in mesh.lods[1].vertices]
        for vertex in vertices:
            self.assertLessEqual(min(math.dist(vertex[:3], point) for point in retained),
                                 mesh.lods[1].error)

    def test_selection_spreads_roots_and_preserves_tall_silhouette(self):
        vertices, indices, ids = blade_fixture()
        components, descriptors = cook._blade_components(vertices, indices, ids, 0.0001, "test")
        self.assertEqual(cook._select_blades(components, descriptors, 24), [7, 0])
        self.assertTrue(all(len(descriptor) == 4 for descriptor in descriptors.values()))
        self.assertTrue(all(descriptor[3] > 0 for descriptor in descriptors.values()))

    def test_two_blades_keep_one_even_below_nominal_budget(self):
        vertices, indices, ids = blade_fixture(2)
        with mock.patch.dict(cook.LOD_POLICIES, {"grass_blades_2": (1.0, 0.001)}):
            mesh = cook.cook_mesh(4, vertices, indices, "grass_blades_2", blade_ids=ids)
        self.assertEqual([len(lod.indices) for lod in mesh.lods], [24, 12])
        self.assertEqual(min(vertex[2] for vertex in mesh.lods[1].vertices), 0)

    def test_target_ties_prefer_lower_triangle_cost(self):
        components = {0: [0] * 12, 1: [0] * 12, 2: [0] * 12}
        descriptors = {0: (0, 0, 3), 1: (1, 0, 1), 2: (0, 1, 2)}
        self.assertEqual(cook._select_blades(components, descriptors, 18), [0])

    def test_component_limits_fail_before_expensive_validation(self):
        vertices, indices, ids = blade_fixture()
        with mock.patch.object(cook, "BLADE_MAX_COUNT", 2):
            with self.assertRaisesRegex(cook.CookError, "limit"):
                cook.cook_mesh(4, vertices, indices, "grass_blades_2", blade_ids=ids)
        with mock.patch.object(cook, "BLADE_MAX_TRIANGLES", 3):
            with self.assertRaisesRegex(cook.CookError, "limit"):
                cook.cook_mesh(4, vertices, indices, "grass_blades_2", blade_ids=ids)

    def test_triangle_reordering_preserves_selected_blades(self):
        vertices, indices, ids = blade_fixture()
        mesh = cook.cook_mesh(4, vertices, indices, "grass_blades_2", blade_ids=ids)
        order = list(reversed(range(len(ids))))
        reordered = [index for triangle in order for index in indices[triangle * 3:triangle * 3 + 3]]
        other = cook.cook_mesh(4, vertices, reordered, "grass_blades_2",
                               blade_ids=[ids[triangle] for triangle in order])
        self.assertEqual(set(mesh.lods[1].vertices), set(other.lods[1].vertices))
        self.assertAlmostEqual(mesh.lods[1].error, other.lods[1].error)

    def test_coarse_blade_roots_round_trip(self):
        vertices, indices, ids = blade_fixture()
        mesh = cook.cook_mesh(4, vertices, indices, "grass_blades_2", blade_ids=ids)
        for packed in (False, True):
            data = cook.serialize([mesh], packed=packed)
            header = struct.unpack_from("<8s10I", data)
            self.assertEqual(header[:4], (cook.MAGIC, cook.VERSION, 1, 2))
            start = cook.HEADER_SIZE + cook.RECORD_SIZE
            vertex_start = start + 2 * cook.LOD_SIZE
            stride = 16 if packed else 36
            for level in range(2):
                first, count, _, _, _, _ = struct.unpack_from("<4I2f", data,
                                                             start + level * cook.LOD_SIZE)
                heights = [struct.unpack_from("<3H" if packed else "<3f", data,
                                             vertex_start + index * stride)[2]
                           for index in range(first, first + count)]
                self.assertEqual(min(heights), 0)

    def test_error_bounds_every_omitted_triangle(self):
        vertices, indices, ids = blade_fixture()
        mesh = cook.cook_mesh(4, vertices, indices, "grass_blades_2", blade_ids=ids)
        retained = {vertex[:3] for vertex in mesh.lods[1].vertices}
        for offset in range(0, len(indices), 3):
            points = [vertices[index][:3] for index in indices[offset:offset + 3]]
            centroid = tuple(sum(point[axis] for point in points) / 3 for axis in range(3))
            self.assertLessEqual(min(math.dist(centroid, point) for point in retained),
                                 mesh.lods[1].error)


class PackTest(unittest.TestCase):
    def test_packed_vertex_is_sixteen_bytes(self):
        bounds = ((0.0, 0.0, 0.0), (1.0, 1.0, 1.0))
        uv_bounds = ((0.0, 0.0), (1.0, 1.0))
        vertex = (0.5, 0.5, 0.5, 0.0, 0.0, 1.0, 1.5, 0.25, 0.75)
        self.assertEqual(len(cook.pack_vertex(vertex, bounds, uv_bounds)), 16)

    def test_position_round_trips_within_half_a_step(self):
        bounds = ((-2.0, -3.0, 0.0), (5.0, 1.0, 9.0))
        uv_bounds = ((0.0, 0.0), (1.0, 1.0))
        vertex = (1.5, -0.25, 4.125, 0.0, 0.0, 1.0, 0.0, 0.25, 0.75)
        packed = cook.pack_vertex(vertex, bounds, uv_bounds)
        fields = struct.unpack("<HHHbbHHBBBB", packed)
        for axis in range(3):
            span = bounds[1][axis] - bounds[0][axis]
            restored = bounds[0][axis] + fields[axis] / 65535.0 * span
            self.assertLessEqual(abs(restored - vertex[axis]), span / (65535.0 * 2))

    def test_flat_axis_does_not_divide_by_zero(self):
        bounds = ((0.0, 0.0, 3.0), (1.0, 1.0, 3.0))
        uv_bounds = ((0.0, 0.0), (0.0, 0.0))
        vertex = (0.5, 0.5, 3.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0)
        fields = struct.unpack("<HHHbbHHBBBB", cook.pack_vertex(vertex, bounds, uv_bounds))
        self.assertEqual(fields[2], 0)


class SerializeTest(unittest.TestCase):
    def _bundle(self, packed=True):
        chain_vertices, chain_indices = grid(16, ripple=0.3)
        clustered_vertices, clustered_indices = grid(32, ripple=0.3)
        return cook.serialize(
            [
                cook.cook_mesh(1, chain_vertices, chain_indices, policy="tree_4"),
                cook.cook_mesh(2, clustered_vertices, clustered_indices, clustered=True),
            ],
            packed=packed,
        )

    def test_header_matches_the_documented_layout(self):
        data = self._bundle()
        fields = struct.unpack_from("<8sIIIIIIIIII", data, 0)
        self.assertEqual(fields[0], cook.MAGIC)
        self.assertEqual(fields[1], cook.VERSION)
        self.assertEqual(fields[2], 2)
        self.assertEqual(fields[8], cook.FLAG_PACKED_VERTICES | cook.FLAG_CLUSTERS)
        self.assertEqual(fields[9:], (0, 0))

    def test_length_is_exactly_the_sum_of_its_sections(self):
        data = self._bundle()
        header = struct.unpack_from("<8sIIIIIIIIII", data, 0)
        _, _, meshes, lods, clusters, groups, vertices, indices, flags, _, _ = header
        expected = cook.HEADER_SIZE
        expected += meshes * cook.RECORD_SIZE
        expected += lods * cook.LOD_SIZE
        expected += clusters * cook.CLUSTER_SIZE
        expected += groups * cook.GROUP_SIZE
        expected += vertices * (16 if flags & cook.FLAG_PACKED_VERTICES else 36)
        expected += indices * 4
        self.assertEqual(len(data), expected)

    def test_packing_shrinks_the_vertex_payload_by_the_expected_ratio(self):
        packed = self._bundle(packed=True)
        fat = self._bundle(packed=False)
        header = struct.unpack_from("<8sIIIIIIIIII", fat, 0)
        vertex_count = header[6]
        self.assertEqual(len(fat) - len(packed), vertex_count * (36 - 16))

    def test_duplicate_ids_are_rejected(self):
        vertices, indices = grid(4)
        mesh = cook.cook_mesh(1, vertices, indices)
        with self.assertRaises(cook.CookError):
            cook.serialize([mesh, mesh])

    def test_write_bundle_is_atomic_and_check_detects_staleness(self):
        data = self._bundle()
        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, "test.ingmesh")
            cook.write_bundle(path, data)
            with open(path, "rb") as handle:
                self.assertEqual(handle.read(), data)
            cook.write_bundle(path, data, check=True)
            with self.assertRaises(cook.CookError):
                cook.write_bundle(path, data + b"\x00", check=True)
            self.assertEqual(os.listdir(directory), ["test.ingmesh"])

    def test_cook_is_reproducible(self):
        # Byte-for-byte reproducibility is what lets `assets-check` mean
        # anything; a nondeterministic partitioner would make it noise.
        self.assertEqual(self._bundle(), self._bundle())


if __name__ == "__main__":
    unittest.main()

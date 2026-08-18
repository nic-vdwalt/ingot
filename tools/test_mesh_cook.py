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

import json
import os
import pathlib
import tempfile
import struct
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
try:
    import bpy
except ImportError:
    bpy = None

if bpy is not None:
    import blender_ingmesh_export as exporter


@unittest.skipIf(bpy is None, "requires Blender")
class BlenderGrassExportTest(unittest.TestCase):
    def setUp(self):
        bpy.ops.wm.read_factory_settings(use_empty=True)
        self.record = {"name": "Grass", "grounded": True, "materials": {"TF_Grass"},
                       "lod_policy": "grass_blades_2", "cluster": False}

    def fixture(self, alternate=False):
        vertices, faces, ids = [], [], []
        for blade in range(4):
            start = len(vertices)
            offset = blade * 0.3
            vertices.extend(((offset, 0, 0), (offset + 0.1, 0, 0),
                             (offset + 0.08, 0, 1), (offset + 0.02, 0, 1)))
            local = [(0, 1, 2, 3), (3, 2, 1, 0)]
            if alternate:
                local = [(0, 1, 2), (0, 2, 3), (3, 2, 1), (3, 1, 0)]
            faces.extend(tuple(start + index for index in face) for face in local)
            ids.extend([blade] * len(local))
        mesh = bpy.data.meshes.new("Grass")
        mesh.from_pydata(vertices, [], faces)
        mesh.materials.append(bpy.data.materials.new("TF_Grass"))
        uv = mesh.uv_layers.new(name="UVMap")
        for index, corner in enumerate(uv.data):
            corner.uv = (float(index % 2), float((index // 2) % 2))
        attribute = mesh.attributes.new("ingot_blade_id", "INT", "FACE")
        for entry, blade_id in zip(attribute.data, ids):
            entry.value = blade_id
        obj = bpy.data.objects.new("Grass", mesh)
        bpy.context.collection.objects.link(obj)
        obj["ingot_mesh_id"] = 4
        return obj

    def test_real_triangulation_and_round_trip(self):
        for alternate in (False, True):
            with self.subTest(alternate=alternate):
                bpy.ops.wm.read_factory_settings(use_empty=True)
                obj = self.fixture(alternate)
                vertices, indices, minimum, maximum, ids = exporter.mesh_payload(obj, self.record)
                self.assertEqual(len(indices), 48)
                self.assertEqual({key: ids.count(key) for key in set(ids)},
                                 {0: 4, 1: 4, 2: 4, 3: 4})
                self.assertEqual(minimum[2], 0)
                self.assertEqual(maximum[2], 1)
                self.assertGreater(len({vertex[3:6] for vertex in vertices}), 1)
                meshes = exporter.collect_meshes({4: self.record})
                for packed in (False, True):
                    data = exporter.serialize_v2(meshes, {4: self.record}, packed)
                    self.assertEqual(struct.unpack_from("<8s3I", data), (b"INGMESH2", 2, 1, 2))
                    self.assertEqual(data, exporter.serialize_v2(meshes, {4: self.record}, packed))
                    first, count, _, indices_count, _, _ = struct.unpack_from("<4I2f", data, 140)
                    self.assertEqual(indices_count, 12)
                    stride = 16 if packed else 36
                    heights = [struct.unpack_from("<3H" if packed else "<3f", data,
                                                  164 + index * stride)[2]
                               for index in range(first, first + count)]
                    self.assertEqual(min(heights), 0)

    def test_missing_wrong_and_negative_attributes_fail(self):
        obj = self.fixture()
        obj.data.attributes.remove(obj.data.attributes["ingot_blade_id"])
        with self.assertRaisesRegex(ValueError, "integer FACE"):
            exporter.mesh_payload(obj, self.record)
        wrong = obj.data.attributes.new("ingot_blade_id", "FLOAT", "FACE")
        with self.assertRaisesRegex(ValueError, "integer FACE"):
            exporter.mesh_payload(obj, self.record)
        obj.data.attributes.remove(wrong)
        attribute = obj.data.attributes.new("ingot_blade_id", "INT", "FACE")
        attribute.data[0].value = -1
        with self.assertRaisesRegex(ValueError, "nonnegative"):
            exporter.mesh_payload(obj, self.record)

    def test_legacy_format_and_clustered_policy_reject_blades(self):
        self.fixture()
        meshes = exporter.collect_meshes({4: self.record})
        with self.assertRaisesRegex(ValueError, "format v2"):
            exporter.serialize(meshes)
        clustered = dict(self.record, cluster=True)
        with self.assertRaisesRegex(ValueError, "clustered"):
            exporter.serialize_v2(meshes, {4: clustered}, True)

    def test_generic_grounded_and_legacy_export_remain_supported(self):
        self.fixture()
        record = dict(self.record, lod_policy="none")
        meshes = exporter.collect_meshes({4: record})
        self.assertIsNone(meshes[0][-1])
        self.assertTrue(exporter.serialize(meshes))
        data = exporter.serialize_v2(meshes, {4: record}, True)
        self.assertEqual(struct.unpack_from("<8s3I", data), (b"INGMESH2", 2, 1, 1))


if __name__ == "__main__":
    result = unittest.TextTestRunner(verbosity=2).run(
        unittest.defaultTestLoader.loadTestsFromTestCase(BlenderGrassExportTest))
    if not result.wasSuccessful():
        raise RuntimeError("Blender grass export tests failed")

import json
import os
import pathlib
import tempfile
import struct
import sys
import unittest
from unittest import mock

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
                for triangle, blade_id in enumerate(ids):
                    for index in indices[triangle * 3:triangle * 3 + 3]:
                        self.assertGreaterEqual(vertices[index][0], blade_id * 0.3 - 1e-6)
                        self.assertLessEqual(vertices[index][0], blade_id * 0.3 + 0.1 + 1e-6)
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

    def test_scene_file_round_trip_and_freshness(self):
        self.fixture()
        parent = pathlib.Path(__file__).resolve().parent
        with tempfile.TemporaryDirectory(prefix="grass-export-", dir=parent) as directory:
            scene = pathlib.Path(directory) / "grass.blend"
            manifest = pathlib.Path(directory) / "manifest.json"
            output = pathlib.Path(directory) / "grass.ingmesh"
            record = dict(self.record, id=4, group="flora", materials=["TF_Grass"])
            manifest.write_text(json.dumps({"version": 1, "meshes": [record]}))
            bpy.context.preferences.filepaths.save_version = 0
            bpy.ops.wm.save_as_mainfile(filepath=str(scene), check_existing=False)
            exporter.export_bundle(str(scene), str(output), str(manifest), False, "v2", True)
            first = output.read_bytes()
            exporter.export_bundle(str(scene), str(output), str(manifest), True, "v2", True)
            self.assertEqual(first, output.read_bytes())
            output.write_bytes(first + b"invalid")
            with self.assertRaisesRegex(ValueError, "stale"):
                exporter.export_bundle(str(scene), str(output), str(manifest), True, "v2", True)
            record["cluster"] = True
            manifest.write_text(json.dumps({"version": 1, "meshes": [record]}))
            with self.assertRaisesRegex(ValueError, "both cluster and lod_policy"):
                exporter.load_manifest(str(manifest))

    def test_triangulation_identity_corruption_is_rejected(self):
        obj = self.fixture()
        original = exporter.blade_attribute
        calls = 0

        def corrupt(mesh, label):
            nonlocal calls
            calls += 1
            attribute = original(mesh, label)
            if calls == 3:
                attribute.data[0].value = 99
            return attribute

        with mock.patch.object(exporter, "blade_attribute", side_effect=corrupt):
            with self.assertRaisesRegex(ValueError, "triangulation changed blade identity"):
                exporter.mesh_payload(obj, self.record)
        self.assertEqual(obj.data.attributes["ingot_blade_id"].data[0].value, 0)
        self.assertEqual(len(exporter.mesh_payload(obj, self.record)[-1]), 16)

    def test_wrong_domain_attribute_fails(self):
        obj = self.fixture()
        obj.data.attributes.remove(obj.data.attributes["ingot_blade_id"])
        obj.data.attributes.new("ingot_blade_id", "INT", "POINT")
        with self.assertRaisesRegex(ValueError, "integer FACE"):
            exporter.mesh_payload(obj, self.record)

    def test_stored_ground_validation_rejects_detached_level(self):
        obj = self.fixture()
        vertices, indices, _, _, ids = exporter.mesh_payload(obj, self.record)
        mesh = exporter.mesh_cook.cook_mesh(4, vertices, indices, "grass_blades_2", blade_ids=ids)
        mesh.lods[1].vertices = [vertex[:2] + (0.5,) + vertex[3:]
                                for vertex in mesh.lods[1].vertices]
        for packed in (False, True):
            with self.assertRaisesRegex(ValueError, "stored level 1"):
                exporter.validate_stored_ground(mesh, packed)

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

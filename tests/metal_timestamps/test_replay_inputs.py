import base64
import unittest

from replay_inputs import ATLAS_DIM, atlas_pixels, window_geometry


class GeometryReplayTests(unittest.TestCase):
    def setUp(self):
        self.vertex = dict(position_bits=[0x80000000, 1],
                           color_bits=[0x7fc01234, 0xff800000, 0x3f800000, 0],
                           uv_bits=[0x3ab60b61, 0x3f800001], mode=1)
        self.payload = dict(version=7, geometry=[dict(vertices=[self.vertex], indices=[0])])
        self.draw = dict(geometry_id=1, projection_known=True, indexed=True,
                         path="Batch_Builtin", known=True,
                         count=1, instances=1, projection_bits=[1, 2, 3, 4])

    def test_exact_little_endian_vertex_layout(self):
        vertices, indices, projection = window_geometry(self.payload, self.draw)
        self.assertEqual(len(vertices), 36)
        self.assertEqual(vertices[:8].hex(), "0000008001000000")
        self.assertEqual(vertices[8:12].hex(), "3412c07f")
        self.assertEqual(vertices[-4:], b"\x01\x00\x00\x00")
        self.assertEqual(indices, bytes(4))
        self.assertEqual(projection.hex(), "01000000020000000300000004000000")

    def test_rejects_missing_and_mismatched_draws(self):
        for field, value in [("geometry_id", 0), ("count", 2),
                             ("projection_known", False), ("instances", 2),
                             ("path", "Gpu_3D"), ("known", False)]:
            with self.subTest(field=field):
                draw = dict(self.draw, **{field: value})
                with self.assertRaises(ValueError):
                    window_geometry(self.payload, draw)

    def test_rejects_invalid_index_and_words(self):
        self.payload["geometry"][0]["indices"] = [1]
        with self.assertRaises(ValueError):
            window_geometry(self.payload, self.draw)
        self.payload["geometry"][0]["indices"] = [0]
        self.vertex["position_bits"] = [-1, 0]
        with self.assertRaises(ValueError):
            window_geometry(self.payload, self.draw)


class AtlasReplayTests(unittest.TestCase):
    def setUp(self):
        self.payload = {
            "version": 7, "atlas_count": 2, "atlas_dropped": 1,
            "atlas_bytes": base64.b64encode(bytes([11, 12, 99, 21])).decode(),
            "atlas_uploads": [
                dict(atlas_id=1, x=3, y=5, width=2, height=1,
                     byte_offset=0, byte_count=2),
                dict(atlas_id=2, x=3, y=5, width=1, height=1,
                     byte_offset=2, byte_count=1),
                dict(atlas_id=1, x=3, y=5, width=1, height=1,
                     byte_offset=3, byte_count=1),
            ],
        }
        self.draw = dict(atlas_id=1, atlas_upload_count=2, atlas_known=True)

    def test_prefix_excludes_later_updates_and_other_atlases(self):
        pixels = atlas_pixels(self.payload, self.draw)
        start = 5 * ATLAS_DIM + 3
        self.assertEqual(pixels[start:start + 2], bytes([11, 12]))
        self.assertEqual(sum(pixels), 23)
        self.draw["atlas_upload_count"] = 3
        pixels = atlas_pixels(self.payload, self.draw)
        self.assertEqual(pixels[start:start + 2], bytes([21, 12]))

    def test_rejects_unknown_or_missing_prefix(self):
        self.draw["atlas_known"] = False
        with self.assertRaises(ValueError):
            atlas_pixels(self.payload, self.draw)
        self.draw["atlas_known"] = True
        self.draw["atlas_upload_count"] = 4
        with self.assertRaises(ValueError):
            atlas_pixels(self.payload, self.draw)

    def test_rejects_invalid_ranges(self):
        for field, value in [("x", ATLAS_DIM), ("byte_offset", 100),
                             ("byte_count", 1), ("height", 0)]:
            with self.subTest(field=field):
                upload = self.payload["atlas_uploads"][0]
                original = upload[field]
                upload[field] = value
                with self.assertRaises(ValueError):
                    atlas_pixels(self.payload, self.draw)
                upload[field] = original

    def test_zero_base_and_numeric_byte_array(self):
        self.payload["atlas_bytes"] = [11, 12, 99, 21]
        self.draw["atlas_upload_count"] = 0
        self.assertEqual(sum(atlas_pixels(self.payload, self.draw)), 0)

import unittest

from window_readiness import selected_window_readiness


class WindowReadinessTests(unittest.TestCase):
    def test_retained_inputs_still_require_build_and_topology(self):
        vertex = dict(position_bits=[0, 0], color_bits=[0, 0, 0, 0], uv_bits=[0, 0], mode=0)
        payload = dict(version=8, batch_shader="captured shader",
                       geometry=[dict(vertices=[vertex], indices=[0, 0, 0])])
        draw = dict(geometry_id=1, projection_known=True, indexed=True, path=1, known=True,
                    count=3, instances=1, projection_bits=[1, 1, 1, 0], pipeline_kind=0,
                    pipeline_style=0, shader_id=0, neutral_texture=True, atlas_id=0,
                    atlas_known=False, scissor=[0, 0, 2560, 1440])
        record = dict(clear_bits_known=True, color_clear_bits=[0, 0, 0, 0], depth_clear_bits=0, load=2,
                      store=1, sample_count=1, format=27, width=2560, height=1440,
                      encoder_id=1, submit_ordinal=1, resolve_ordinal=1, resolve_encoder_id=1,
                      epoch=1, frame=1, generation=1, map_request=1, depth_format=0,
                      label=dict(length=6, bytes=list(b"window")), callback_status=1,
                      query_begin=0, slot_index=0, begin_tick=123, end_tick=0,
                      draw_count=1, draws=[draw], draws_dropped=0, previous=dict(valid=False))
        report = selected_window_readiness(payload, record)
        self.assertEqual({item["field"] for item in report["missing_inputs"]},
                         {"source_manifest", "pipeline_descriptor", "queue_topology"})
        self.assertFalse(report["ready"])
        draw["neutral_texture"] = False
        report = selected_window_readiness(payload, record)
        self.assertIn("draws[0].texture", {item["field"] for item in report["missing_inputs"]})

    def test_missing_evidence_is_not_ready(self):
        report = selected_window_readiness({}, {})
        self.assertFalse(report["ready"])
        fields = {entry["field"] for entry in report["missing_inputs"]}
        self.assertTrue({"draws", "clear_bits_known", "source_manifest",
                         "queue_topology"}.issubset(fields))

    def test_numeric_clear_store_are_recognized(self):
        report = selected_window_readiness({"version": 7}, {"load": 2, "store": 1})
        fields = {entry["field"] for entry in report["missing_inputs"]}
        self.assertNotIn("load", fields)
        self.assertNotIn("store", fields)
        self.assertFalse(report["ready"])

    def test_load_and_dropped_draws_remain_incomplete(self):
        record = {"load": 1, "store": 1, "draw_count": 5,
                  "draws_dropped": 1, "draws": [{}] * 4}
        report = selected_window_readiness({"version": 7}, record)
        fields = {entry["field"] for entry in report["missing_inputs"]}
        self.assertTrue({"load", "draws", "draws_dropped"}.issubset(fields))

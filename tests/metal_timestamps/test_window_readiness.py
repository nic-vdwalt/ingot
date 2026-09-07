import unittest

from window_readiness import selected_window_readiness


class WindowReadinessTests(unittest.TestCase):
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

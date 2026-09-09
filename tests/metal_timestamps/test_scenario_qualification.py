import copy
import unittest

from scenario_qualification import validate_scenario, verify_delivery_mapping


def history():
    base = dict(
        v=2, scenario="ocean", seed="542318199907", quality="fixed",
        width=1280, height=720, render_scale=1, opaque_method="intact pass",
        terrain_sha256="a" * 64, requested_warmup=5, requested_duration=20,
        clock_domain="context_monotonic_seconds", clock_revision=1,
        frame_epoch=1, frame_mapping_valid=True, frame_boundary="before_game_draw",
        minimized=False, hidden=False, occluded=False, visibility_interrupted=False,
        publication_failed=False, terminal=False, terminal_outcome="",
        measurement_started=False, measured_started=0,
    )
    return [
        dict(base, phase="warmup", native_seconds=10, actual_elapsed=0, frame_index=1),
        dict(base, phase="measured", native_seconds=15, actual_elapsed=5, frame_index=300,
             measurement_started=True, measured_started=15),
        dict(base, phase="cooldown", native_seconds=35, actual_elapsed=25, frame_index=1500,
             terminal=True, terminal_outcome="completed",
             measurement_started=True, measured_started=15),
    ]


class ScenarioQualificationTests(unittest.TestCase):
    def test_valid_history_has_exclusive_frame_end(self):
        result = validate_scenario(history())
        self.assertEqual(result, {"reasons": [], "ranges": [(1, 300, 1500)]})

    def test_late_first_measured_frame_requires_full_actual_duration(self):
        records = history()
        records[1].update(native_seconds=15.1, actual_elapsed=5.1, measured_started=15.1)
        records[-1]["measured_started"] = 15.1
        self.assertIn("measured_duration_incomplete", validate_scenario(records)["reasons"])
        records[-1].update(native_seconds=35.2, actual_elapsed=25.2)
        self.assertEqual(validate_scenario(records)["reasons"], [])

    def test_bad_protocol_never_selects_frames(self):
        for field, value in (
            ("frame_index", 0), ("frame_epoch", True), ("frame_mapping_valid", False),
            ("clock_revision", 0), ("clock_domain", "wall"), ("v", 1),
            ("visibility_interrupted", True), ("publication_failed", True),
            ("native_seconds", float("nan")), ("actual_elapsed", -1),
            ("render_scale", 0.75), ("terrain_sha256", "z" * 64),
        ):
            with self.subTest(field=field, value=value):
                records = history()
                records[1][field] = value
                result = validate_scenario(records)
                self.assertTrue(result["reasons"])
                self.assertEqual(result["ranges"], [])

    def test_numeric_equality_cannot_hide_wire_type_changes(self):
        for field, value in (("render_scale", True), ("width", 1280.0),
                             ("requested_warmup", 5.0), ("frame_index", 2**64),
                             ("frame_epoch", 2**64)):
            with self.subTest(field=field):
                records = history()
                records[1][field] = value
                self.assertEqual(validate_scenario(records)["ranges"], [])
        records = history()
        records[0]["measured_started"] = False
        self.assertIn("invalid_measured_start", validate_scenario(records)["reasons"])

    def test_nonterminal_cooldown_cannot_close_measured_range(self):
        records = history()
        cooldown = dict(records[-1], terminal=False, terminal_outcome="")
        records.insert(-1, cooldown)
        records[-1].update(native_seconds=36, actual_elapsed=26, frame_index=1560)
        result = validate_scenario(records)
        self.assertIn("nonterminal_cooldown_boundary", result["reasons"])
        self.assertEqual(result["ranges"], [])

    def test_terminal_and_duration_are_required(self):
        for records in (history()[:-1], history() + [copy.deepcopy(history()[-1])]):
            self.assertEqual(validate_scenario(records)["ranges"], [])
        records = history()
        records[-1]["native_seconds"] -= 0.1
        self.assertIn("measured_duration_incomplete", validate_scenario(records)["reasons"])

    def test_delivery_clock_requires_origin_and_exact_boundary(self):
        records = history()
        for record in records:
            record["clock_origin_seconds"] = 1000
        deliveries = {
            (record["frame_epoch"], record["frame_index"]):
                {"st": 1000 + record["native_seconds"] + 0.01}
            for record in records
        }
        self.assertIn("scenario_frame_ownership_gap", verify_delivery_mapping(records, deliveries))
        for start, end in zip(records, records[1:]):
            for frame in range(start["frame_index"], end["frame_index"]):
                fraction = (frame - start["frame_index"]) / (end["frame_index"] - start["frame_index"])
                deliveries[(1, frame)] = {"st": 1000 + start["native_seconds"] +
                    fraction * (end["native_seconds"] - start["native_seconds"]) + 0.001}
        self.assertEqual(verify_delivery_mapping(records, deliveries), [])
        deliveries[(1, 300)]["st"] = 15.01
        self.assertIn("scenario_delivery_clock_mismatch", verify_delivery_mapping(records, deliveries))
        del deliveries[(1, 1500)]
        self.assertIn("scenario_boundary_delivery_missing", verify_delivery_mapping(records, deliveries))
        records[0]["clock_origin_seconds"] = 0
        self.assertIn("delivery_clock_origin_unverified", verify_delivery_mapping(records, deliveries))

    def test_absolute_clock_sum_overflow_fails_closed(self):
        records = history()
        for record in records:
            record.update(clock_origin_seconds=1e308, native_seconds=1e308)
        reasons = verify_delivery_mapping(records, {})
        self.assertIn("delivery_clock_origin_unverified", reasons)

    def test_reversed_and_cross_epoch_frames_fail(self):
        for field, value in (("frame_index", 299), ("frame_epoch", 2)):
            records = history()
            records[-1][field] = value
            self.assertIn("nonmonotonic_scenario_frame", validate_scenario(records)["reasons"])


if __name__ == "__main__":
    unittest.main()

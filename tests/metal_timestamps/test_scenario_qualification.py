import copy
import unittest

from scenario_qualification import validate_scenario


def history():
    base = dict(
        v=2, scenario="ocean", seed="542318199907", quality="fixed",
        width=1280, height=720, render_scale=1, opaque_method="intact pass",
        terrain_sha256="a" * 64, requested_warmup=5, requested_duration=20,
        clock_domain="context_monotonic_seconds", clock_revision=1,
        frame_epoch=1, frame_mapping_valid=True, frame_boundary="before_game_draw",
        minimized=False, hidden=False, occluded=False, visibility_interrupted=False,
        publication_failed=False, terminal=False, terminal_outcome="",
    )
    return [
        dict(base, phase="warmup", native_seconds=10, actual_elapsed=0, frame_index=1),
        dict(base, phase="measured", native_seconds=15, actual_elapsed=5, frame_index=300),
        dict(base, phase="cooldown", native_seconds=35, actual_elapsed=25, frame_index=1500,
             terminal=True, terminal_outcome="completed"),
    ]


class ScenarioQualificationTests(unittest.TestCase):
    def test_valid_history_has_exclusive_frame_end(self):
        result = validate_scenario(history())
        self.assertEqual(result, {"reasons": [], "ranges": [(1, 300, 1500)]})

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

    def test_terminal_and_duration_are_required(self):
        for records in (history()[:-1], history() + [copy.deepcopy(history()[-1])]):
            self.assertEqual(validate_scenario(records)["ranges"], [])
        records = history()
        records[-1]["native_seconds"] -= 0.1
        self.assertIn("measured_duration_incomplete", validate_scenario(records)["reasons"])

    def test_reversed_and_cross_epoch_frames_fail(self):
        for field, value in (("frame_index", 299), ("frame_epoch", 2)):
            records = history()
            records[-1][field] = value
            self.assertIn("nonmonotonic_scenario_frame", validate_scenario(records)["reasons"])


if __name__ == "__main__":
    unittest.main()

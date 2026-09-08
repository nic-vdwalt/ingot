import json
import tempfile
import unittest
from pathlib import Path

from evaluate_planetforger_capture import evaluate_capture


IDENTITY = {
    "scenario": "ocean",
    "seed": "7",
    "quality": "fixed",
    "width": 1280,
    "height": 720,
    "refresh_hz": 120,
    "terrain_sha256": "a" * 64,
    "phase": "background",
}


def boundary_fields():
    return {
        "bv": 2,
        "rc": 5.8,
        "hc": 7.1,
        "aq": 1.5,
        "en": 0.2,
        "sb": 0.2,
        "ps": 0.2,
        "pre": 0.1,
        "sta": 0.2,
        "post": 0.3,
        "flu": 0.4,
        "upl": 0.5,
        "cln": 0.6,
        "inp": 0.7,
        "fti": 0.8,
        "hrl": 0.5,
        "hrf": 0.5,
        "hdr": 5,
        "hpr": 0.5,
        "hcu": 0.5,
        "hun": 0.1,
        "qbp": 1,
        "qap": 1,
        "qas": 2,
        "qhw": 2,
        "qoa": 1,
        "iuc": 1,
        "ifc": 1,
        "isc": 1,
        "fuc": 1,
        "ffc": 1,
        "fsc": 1,
        "ium": 0.1,
        "ifm": 0.2,
        "ism": 0.3,
        "fum": 0.4,
        "ffm": 0.5,
        "fsm": 0.6,
    }


def telemetry(groups=None, health=None, missing=False):
    groups = groups or ["window", "world.opaque", "world.scene-copy", "world.ocean"]
    return {
        "rt": 1,
        "sq": 1,
        "gfd": [{
            "e": 1,
            "i": 1,
            "v": True,
            "g": [{"n": name, "ms": 1, "c": 1} for name in groups],
        }],
        "gh": health or {},
        "fd": [{
            "e": 1,
            "i": 1,
            "v": 7,
            "rc": 7,
            "hc": 8,
            "aq": 1,
            "en": 2,
            "sb": 3,
            "ps": 4,
            "pw": 5,
            "st": 10,
            "gt": 10.009,
            "gc": 9,
            "pt": 10.01,
            "mg": missing,
            "mp": False,
        }],
        "rl": {"g": "unreliable", "r": "metal_same_command_buffer_resolve"},
    }


class PlanetForgerCaptureTests(unittest.TestCase):
    def evaluate(self, records, scenarios=None, recording=None):
        with tempfile.TemporaryDirectory() as directory:
            telemetry_path = Path(directory) / "capture.tel"
            scenario_path = Path(directory) / "capture.tel.scenario.jsonl"
            recording_path = Path(directory) / "recording.jsonl"
            telemetry_path.write_text("\n".join(json.dumps(record) for record in records))
            scenario_path.write_text("\n".join(json.dumps(record) for record in scenarios or [IDENTITY]))
            if recording is not None:
                recording_path.write_text("\n".join(json.dumps(record) for record in recording))
            return evaluate_capture(
                telemetry_path,
                scenario_path,
                recording_path=recording_path if recording is not None else None,
            )

    def test_accepts_healthy_unsegmented_capture(self):
        result = self.evaluate([telemetry()])
        self.assertTrue(result["accepted"])
        self.assertEqual(result["observed_phases"], ["background"])
        self.assertEqual(result["completion_high_water"], 0)

    def test_rejects_missing_group(self):
        result = self.evaluate([telemetry(["window", "world.opaque", "world.scene-copy"])])
        self.assertFalse(result["accepted"])
        self.assertFalse(result["complete_groups"])

    def test_rejects_health_or_delivery_failure(self):
        for record in (telemetry(health={"sf": 1}), telemetry(missing=True)):
            with self.subTest(record=record):
                self.assertFalse(self.evaluate([record])["accepted"])

    def test_rejects_changed_scenario_identity(self):
        changed = dict(IDENTITY)
        changed["seed"] = "8"
        with self.assertRaisesRegex(ValueError, "identity changes"):
            self.evaluate([telemetry()], [IDENTITY, changed])

    def test_counts_sequence_gaps_and_duplicates(self):
        records = [telemetry(), telemetry(), telemetry()]
        records[1]["sq"] = 1
        records[2]["sq"] = 3
        result = self.evaluate(records)
        self.assertEqual(result["failures"]["sequence_duplicates"], 1)
        self.assertEqual(result["failures"]["sequence_gaps"], 1)
        self.assertFalse(result["accepted"])

    def test_requires_clean_recording_when_supplied(self):
        healthy = [
            {"k": "telemetry_health", "startup_absent": 1},
            {"k": "end", "e": True, "c": 0, "z": False},
        ]
        result = self.evaluate([telemetry()], recording=healthy)
        self.assertTrue(result["accepted"])
        self.assertTrue(result["recording"]["healthy"])
        unhealthy = [
            {"k": "telemetry_health", "parse_errors": 1},
            {"k": "end", "e": True, "c": 0, "z": False},
        ]
        self.assertFalse(self.evaluate([telemetry()], recording=unhealthy)["accepted"])

    def test_rejects_incomplete_recording(self):
        with self.assertRaisesRegex(ValueError, "exactly one"):
            self.evaluate([telemetry()], recording=[{"k": "telemetry_health"}])

    def test_reports_existing_exact_frame_metrics(self):
        result = self.evaluate([telemetry()])
        self.assertEqual(result["host_ms"]["p50"], 8)
        self.assertEqual(result["renderer_ms"]["p50"], 7)
        self.assertEqual(result["acquire_ms"]["p50"], 1)
        self.assertEqual(result["encode_ms"]["p50"], 2)
        self.assertEqual(result["submit_ms"]["p50"], 3)
        self.assertEqual(result["present_call_ms"]["p50"], 4)
        self.assertEqual(result["pacer_wait_ms"]["p50"], 5)
        self.assertEqual(result["queue_completion_ms"]["p50"], 9)
        self.assertEqual(result["exact_gpu_ms"]["p50"], None)
        self.assertEqual(result["gpu_groups_ms"]["window"]["p50"], 1)

    def test_absent_cpu_metrics_are_not_measured_zeroes(self):
        record = telemetry()
        for field in ("rc", "aq", "en", "sb", "ps", "pw"):
            del record["fd"][0][field]
        result = self.evaluate([record])
        self.assertEqual(result["renderer_ms"]["count"], 0)
        self.assertEqual(result["acquire_ms"]["count"], 0)
        self.assertTrue(result["accepted"])

    def test_rejects_negative_cpu_duration(self):
        record = telemetry()
        record["fd"][0]["aq"] = -1
        result = self.evaluate([record])
        self.assertEqual(result["failures"]["invalid_cpu_durations"], 1)
        self.assertFalse(result["accepted"])

    def test_reports_complete_boundary_accounting(self):
        record = telemetry()
        record["fd"][0].update(boundary_fields())
        result = self.evaluate([record])
        self.assertEqual(result["boundary_schema"]["versions"], [2])
        self.assertEqual(result["boundary_schema"]["detailed_frames"], 1)
        self.assertEqual(result["boundary_ms"]["host_closure_error"]["p50"], 0)
        self.assertAlmostEqual(result["boundary_ms"]["renderer_unaccounted"]["p50"], 0.1)
        self.assertEqual(result["classification_counts"]["drawable_acquisition"], 1)

    def test_rejects_incomplete_or_unknown_boundary_schema(self):
        incomplete = telemetry()
        incomplete["fd"][0].update(boundary_fields())
        del incomplete["fd"][0]["pre"]
        result = self.evaluate([incomplete])
        self.assertEqual(result["failures"]["incomplete_boundary_frames"], 1)
        self.assertFalse(result["accepted"])
        unknown = telemetry()
        unknown["fd"][0]["bv"] = 3
        result = self.evaluate([unknown])
        self.assertEqual(result["failures"]["unknown_boundary_frames"], 1)
        self.assertFalse(result["accepted"])

    def test_classifies_submission_pressure_before_acquire(self):
        record = telemetry()
        fields = boundary_fields()
        fields["qap"] = 3
        fields["qoa"] = 2
        record["fd"][0].update(fields)
        result = self.evaluate([record])
        self.assertEqual(result["classification_counts"]["submission_pressure"], 1)
        self.assertEqual(result["boundary_schema"]["long_frames"], 0)
        self.assertEqual(result["boundary_schema"]["acquire_frames_classified"], 1)

    def test_legacy_boundary_fields_remain_unavailable(self):
        result = self.evaluate([telemetry()])
        self.assertEqual(result["boundary_schema"]["versions"], [0])
        self.assertEqual(result["boundary_ms"]["host_closure_error"]["count"], 0)
        self.assertTrue(result["accepted"])

    def test_rejects_reversed_async_timestamps(self):
        record = telemetry()
        record["fd"][0]["gt"] = 9
        result = self.evaluate([record])
        self.assertEqual(result["failures"]["reversed_gpu_timestamps"], 1)
        self.assertFalse(result["accepted"])


if __name__ == "__main__":
    unittest.main()

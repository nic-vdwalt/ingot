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

    def test_rejects_reversed_async_timestamps(self):
        record = telemetry()
        record["fd"][0]["gt"] = 9
        result = self.evaluate([record])
        self.assertEqual(result["failures"]["reversed_gpu_timestamps"], 1)
        self.assertFalse(result["accepted"])


if __name__ == "__main__":
    unittest.main()

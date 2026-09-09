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
        "bv": 3,
        "rc": 5.8,
        "rdw": 0.1,
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
                recording_path.write_text("\n".join(json.dumps(record) for record in recording) + "\n")
            return evaluate_capture(
                telemetry_path,
                scenario_path,
                recording_path=recording_path if recording is not None else None,
            )

    def test_malformed_nested_telemetry_preserves_other_reliability_evidence(self):
        mutations = [
            ((name,), value)
            for name in ("gh", "rl", "gfd", "fd")
            for value in (False, 7, "invalid")
        ]
        mutations += [
            ((name, 0), value)
            for name in ("gfd", "fd") for value in (None, [], False)
        ]
        mutations += [
            ((name, 0, key), value)
            for name in ("gfd", "fd") for key in ("e", "i")
            for value in ([], {}, True, 0, -1, 2**64)
        ]
        mutations += [
            (("gfd", 0, "g"), {}),
            (("gfd", 0, "g", 0), False),
            (("gfd", 0, "g", 0, "n"), []),
            (("gfd", 0, "g", 0, "ms"), None),
            (("gfd", 0, "g", 0, "ms"), float("nan")),
            (("gfd", 0, "g", 0, "ms"), True),
            (("fd", 0, "hc"), {}),
            (("fd", 0, "gc"), float("inf")),
            (("fd", 0, "v"), []),
            (("fd", 0, "bv"), {}),
            (("fd", 0, "mg"), []),
            (("gh", "q"), {}),
            (("sq",), []),
        ]
        for path, value in mutations:
            with self.subTest(path=path, value=value):
                malformed = telemetry()
                target = malformed
                for key in path[:-1]:
                    target = target[key]
                target[path[-1]] = value
                retained = telemetry(missing=True)
                retained["sq"] = 2
                retained["gfd"][0]["i"] = 2
                retained["fd"][0]["i"] = 2
                result = self.evaluate([malformed, retained])
                self.assertFalse(result["qualified"])
                self.assertTrue(any(reason.startswith("telemetry_schema_invalid:")
                                    for reason in result["qualification_reasons"]))
                self.assertGreaterEqual(result["joined_frames"], 1)
                self.assertGreaterEqual(result["failures"]["missing_gpu_callbacks"], 1)

    def test_recording_investigation_rejects_malformed_typed_fields(self):
        for field, value in (
            ("frame_index", True), ("frame_epoch", 2**64), ("width", 2**31),
            ("clock_revision", -1), ("publication_failed", []), ("native_seconds", False),
            ("clock_origin_seconds", float("nan")), ("seed", 7),
            ("camera_position", [1, 2]), ("camera_target", [0, True, 0]),
            ("camera_position", [0, 1e100, 0]),
        ):
            with self.subTest(field=field, value=value):
                result = self.evaluate([telemetry()], recording=[
                    {"k": "run", "v": 2},
                    {"k": "investigation", "v": 2, field: value},
                    {"k": "telemetry_health", "invalid_lines": 0},
                    {"k": "end", "e": True, "c": 0, "z": False},
                ])
                self.assertFalse(result["qualified"])
                self.assertIn("recording_investigation_field_invalid:" + field,
                              result["qualification_reasons"])

    def test_recording_recognized_fields_reject_wrong_wire_types(self):
        cases = (
            ("run", "p", True), ("run", "i", []), ("run", "m", 7),
            ("sample", "q", 256), ("sample", "r", 1e100),
            ("sample", "v", False), ("sample", "t", float("nan")),
            ("phase", "name", {}), ("activation", "attempt", False),
            ("activation", "known", 1), ("end", "c", 2**31),
            ("end", "s", []), ("end", "e", 1), ("tel", "y", []),
        )
        for kind, field, value in cases:
            with self.subTest(kind=kind, field=field):
                record = {"k": kind, "v": 2, field: value}
                result = self.evaluate([telemetry()], recording=[record])
                self.assertFalse(result["qualified"])
                self.assertIn("recording_field_invalid:" + kind + "." + field,
                              result["qualification_reasons"])

    def test_recording_nested_telemetry_wire_types(self):
        cases = (
            ({"rt": 2**32}, "rt"), ({"sq": True}, "sq"),
            ({"gh": []}, "gh"), ({"gh": {"co": 2**32}}, "gh.co"),
            ({"gh": {"iv": 1}}, "gh.iv"), ({"rl": {"v": -1}}, "rl.v"),
            ({"fd": [{"v": 256}]}, "fd.0.v"),
            ({"fd": [{"su": 1}]}, "fd.0.su"),
            ({"fd": [{"qoa": 2**64}]}, "fd.0.qoa"),
            ({"gfd": [{"tg": -1}]}, "gfd.0.tg"),
            ({"gfd": [{"g": [{"c": True}]}]}, "gfd.0.g.0.c"),
            ({"gg": [{"n": []}]}, "gg.0.n"),
            ({"p": [{"l": 10**400}]}, "p.0.l"),
            ({"fl": 10**400}, "fl"), ({"rs": 1e100}, "rs"),
            ({"ww": 2**31}, "ww"), ({"grl": "invalid"}, "grl"),
        )
        for value, path in cases:
            with self.subTest(path=path):
                result = self.evaluate([telemetry(missing=True)], recording=[
                    {"k": "tel", "y": value},
                ])
                self.assertFalse(result["qualified"])
                self.assertIn("recording_field_invalid:tel.y." + path,
                              result["qualification_reasons"])
                self.assertEqual(result["failures"]["missing_gpu_callbacks"], 1)

    def test_oversized_scenario_numbers_fail_closed(self):
        for field in ("native_seconds", "refresh_hz"):
            for value in (10**400, [], True):
                with self.subTest(field=field, value=value):
                    scenario = dict(IDENTITY, **{field: value})
                    result = self.evaluate([telemetry(missing=True)], scenarios=[scenario])
                    self.assertFalse(result["qualified"])
                    self.assertEqual(result["failures"]["missing_gpu_callbacks"], 1)

    def test_recording_health_integer_widths(self):
        for field, value in (("startup_absent", 2**64), ("pending_bytes", 2**63),
                             ("invalid_lines", 2**64)):
            with self.subTest(field=field):
                health = dict.fromkeys(("invalid_lines", "parse_errors", "resets",
                                       "read_errors", "pending_bytes", "startup_absent"), 0)
                health.update(discarding=False, unfinished_tail=False, drain_exhausted=False)
                health.update(k="telemetry_health", **{field: value})
                result = self.evaluate([telemetry()], recording=[health])
                self.assertIn("recording_health_fields_invalid", result["qualification_reasons"])

    def test_recording_native_size_limits(self):
        for contents, reason in (
            (b" " * (64 * 1024 + 1) + b"\n", "recording_line_limit_exceeded"),
            (b"{}\n" * (16 * 1024 * 1024 // 3 + 1), "recording_size_limit_exceeded"),
        ):
            with self.subTest(reason=reason), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                (root / "capture").write_text(json.dumps(telemetry()) + "\n")
                (root / "scenario").write_text(json.dumps(IDENTITY) + "\n")
                (root / "recording").write_bytes(contents)
                result = evaluate_capture(root / "capture", root / "scenario",
                                          recording_path=root / "recording")
                self.assertFalse(result["qualified"])
                self.assertIn(reason, result["qualification_reasons"])

    def test_recording_tail_and_blank_lines_are_not_ignored(self):
        for suffix, reason in (("", "recording_unterminated_tail"),
                               ("\n\n", "recording_blank_record")):
            with self.subTest(suffix=suffix), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                (root / "capture").write_text(json.dumps(telemetry()) + "\n")
                (root / "scenario").write_text(json.dumps(IDENTITY) + "\n")
                (root / "recording").write_text(json.dumps({"k": "run", "v": 2}) + suffix)
                result = evaluate_capture(root / "capture", root / "scenario",
                                          recording_path=root / "recording")
                self.assertFalse(result["qualified"])
                self.assertIn(reason, result["qualification_reasons"])

    def test_strict_frame_owned_success_and_full_capture_failures(self):
        from test_scenario_qualification import history
        scenarios = history()
        for record in scenarios:
            record["clock_origin_seconds"] = 1000
        records = []
        for frame in range(1, 1501):
            seconds = 10 + (frame - 1) * 5 / 299 if frame < 300 else 15 + (frame - 300) / 60
            record = telemetry()
            record["sq"] = frame
            record["rl"] = {"g": "reliable", "r": "completion_gated_metal_resolve"}
            record["gfd"][0]["i"] = frame
            record["fd"][0].update(i=frame, st=1000 + seconds + 0.001,
                                   gt=1000 + seconds + 0.009, pt=1000 + seconds + 0.01)
            records.append(record)
        recording = [
            {"k": "run", "v": 2},
            {"k": "telemetry_health", "invalid_lines": 0, "parse_errors": 0,
             "resets": 0, "read_errors": 0, "pending_bytes": 0, "startup_absent": 0,
             "discarding": False, "unfinished_tail": False, "drain_exhausted": False},
            {"k": "end", "e": True, "c": 0, "z": False},
        ]
        result = self.evaluate(records, scenarios, recording)
        self.assertTrue(result["qualified"], result["qualification_reasons"])
        self.assertEqual(result["joined_frames"], 1200)
        invalid_recordings = [
            (recording[1:], "recording_metadata_invalid"),
            ([recording[0], *recording], "recording_metadata_invalid"),
            ([recording[0], {"k": "telemetry_health"}, recording[-1]],
             "recording_health_fields_invalid"),
            ([*recording[:-1], {**recording[-1], "c": False}], "recording_exit_code_invalid"),
            ([recording[0], {**recording[1], "discarding": []}, recording[-1]],
             "recording_health_fields_invalid"),
            ([recording[0], {**recording[1], "parse_errors": False}, recording[-1]],
             "recording_health_fields_invalid"),
        ]
        for version in (0, 3, 2.5, True, "2"):
            invalid_recordings.append((
                [recording[0], {"k": "investigation", "v": version}, *recording[1:]],
                "recording_investigation_version_unsupported",
            ))
        for invalid_recording, reason in invalid_recordings:
            with self.subTest(reason=reason, recording=invalid_recording):
                result = self.evaluate(records, scenarios, invalid_recording)
                self.assertFalse(result["qualified"])
                self.assertIn(reason, result["qualification_reasons"])
                self.assertEqual(result["joined_frames"], 1200)
        for index in (0, 300, 1499):
            records[index]["fd"][0]["mg"] = True
            result = self.evaluate(records, scenarios, recording)
            self.assertFalse(result["qualified"])
            records[index]["fd"][0]["mg"] = False

    def test_accepts_healthy_unsegmented_capture(self):
        result = self.evaluate([telemetry()])
        self.assertTrue(result["accepted"])
        self.assertEqual(result["observed_phases"], ["background"])
        self.assertEqual(result["completion_high_water"], 0)
        self.assertFalse(result["qualified"])
        self.assertIn("no_bounded_measured_phase", result["qualification_reasons"])
        self.assertIn("scenario_completion_unproven", result["qualification_reasons"])

    def test_missing_or_malformed_history_returns_qualification_failure(self):
        for contents in (None, "", "{", "[]", "null", "1"):
            with self.subTest(contents=contents), tempfile.TemporaryDirectory() as directory:
                telemetry_path = Path(directory) / "capture.tel"
                scenario_path = Path(directory) / "scenario.jsonl"
                telemetry_path.write_text(json.dumps(telemetry()))
                if contents is not None:
                    scenario_path.write_text(contents)
                result = evaluate_capture(telemetry_path, scenario_path)
                self.assertFalse(result["qualified"])
                self.assertFalse(result["accepted"])
                self.assertIn("failures", result)
                self.assertIn("raw_without_delivery", result["failures"])
                self.assertIn("delivery_without_raw", result["failures"])
                self.assertIn(
                    "scenario_history_unavailable_or_malformed", result["qualification_reasons"]
                )

    def test_open_measured_history_is_not_qualified(self):
        scenario = dict(IDENTITY, phase="measured", native_seconds=9)
        result = self.evaluate([telemetry()], [scenario])
        self.assertFalse(result["qualified"])
        self.assertIn("open_measured_tail", result["qualification_reasons"])
        self.assertEqual(result["delivery_frames"], 0)

    def test_invalid_timestamp_does_not_select_all_frames(self):
        for timestamp in (float("nan"), float("inf"), -1, True, "9", None):
            with self.subTest(timestamp=timestamp):
                scenarios = [
                    dict(IDENTITY, phase="measured", native_seconds=timestamp),
                    dict(IDENTITY, phase="cooldown", native_seconds=11),
                ]
                result = self.evaluate([telemetry()], scenarios)
                self.assertFalse(result["qualified"])
                self.assertEqual(result["delivery_frames"], 0)
                self.assertIn("invalid_scenario_timestamp", result["qualification_reasons"])

    def test_reversed_history_does_not_select_frames(self):
        scenarios = [
            dict(IDENTITY, phase="warmup", native_seconds=12),
            dict(IDENTITY, phase="measured", native_seconds=9),
            dict(IDENTITY, phase="cooldown", native_seconds=11),
        ]
        result = self.evaluate([telemetry()], scenarios)
        self.assertEqual(result["delivery_frames"], 0)
        self.assertIn("nonmonotonic_scenario_timestamp", result["qualification_reasons"])

    def test_terminal_claim_without_frame_mapping_is_not_qualified(self):
        scenarios = [
            dict(IDENTITY, phase="measured", native_seconds=9),
            dict(IDENTITY, phase="cooldown", native_seconds=11, terminal_outcome="completed"),
        ]
        result = self.evaluate([telemetry()], scenarios)
        self.assertFalse(result["qualified"])
        self.assertIn("scenario_frame_clock_mapping_unverified", result["qualification_reasons"])

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
        result = self.evaluate([telemetry()], [IDENTITY, changed])
        self.assertFalse(result["accepted"])
        self.assertFalse(result["qualified"])
        self.assertIn("scenario_identity_changed", result["qualification_reasons"])
        self.assertIn("failures", result)

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
        for recording in ([], [{}], [None], [{"k": "telemetry_health"}]):
            result = self.evaluate([telemetry()], recording=recording)
            self.assertFalse(result["accepted"])
            self.assertFalse(result["qualified"])
            self.assertIn("failures", result)

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

    def test_measured_phase_filters_gpu_frames_and_groups_by_delivery_identity(self):
        warmup = telemetry()
        warmup["gfd"][0]["ms"] = 20
        warmup["gfd"][0]["g"][0]["ms"] = 10
        warmup["fd"][0]["st"] = 10
        measured = telemetry()
        measured["sq"] = 2
        measured["gfd"][0]["i"] = 2
        measured["gfd"][0]["ms"] = 4
        measured["gfd"][0]["g"][0]["ms"] = 2
        measured["fd"][0]["i"] = 2
        measured["fd"][0]["st"] = 25
        measured["fd"][0]["gt"] = 25.009
        measured["fd"][0]["pt"] = 25.01
        scenarios = [
            {**IDENTITY, "phase": "warmup", "native_seconds": 0},
            {**IDENTITY, "phase": "measured", "native_seconds": 20},
            {**IDENTITY, "phase": "complete", "native_seconds": 30},
        ]
        result = self.evaluate([warmup, measured], scenarios)
        self.assertEqual(result["qualification_route"], "legacy_unqualified")
        self.assertEqual(result["delivery_frames"], 1)
        self.assertEqual(result["gpu_frames"], 1)
        self.assertEqual(result["joined_frames"], 1)
        self.assertEqual(result["exact_gpu_ms"]["p50"], 4)
        self.assertEqual(result["gpu_groups_ms"]["window"]["p50"], 2)
        self.assertEqual(result["group_counts"]["window"], 1)
        self.assertTrue(result["accepted"])

    def test_missing_measured_raw_frame_remains_a_join_failure(self):
        record = telemetry()
        record["gfd"] = []
        record["fd"][0]["st"] = 25
        record["fd"][0]["gt"] = 25.009
        record["fd"][0]["pt"] = 25.01
        scenarios = [
            {**IDENTITY, "phase": "measured", "native_seconds": 20},
            {**IDENTITY, "phase": "complete", "native_seconds": 30},
        ]
        result = self.evaluate([record], scenarios)
        self.assertEqual(result["failures"]["delivery_without_raw"], 1)
        self.assertEqual(result["joined_frames"], 0)
        self.assertFalse(result["accepted"])

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
        self.assertEqual(result["boundary_schema"]["versions"], [3])
        self.assertEqual(result["boundary_schema"]["detailed_frames"], 1)
        self.assertEqual(result["boundary_ms"]["host_closure_error"]["p50"], 0)
        self.assertEqual(result["boundary_ms"]["renderer_unaccounted"]["p50"], 0)
        self.assertEqual(result["classification_counts"]["drawable_acquisition"], 1)

    def test_rejects_incomplete_or_unknown_boundary_schema(self):
        incomplete = telemetry()
        incomplete["fd"][0].update(boundary_fields())
        del incomplete["fd"][0]["pre"]
        result = self.evaluate([incomplete])
        self.assertEqual(result["failures"]["incomplete_boundary_frames"], 1)
        self.assertFalse(result["accepted"])
        unknown = telemetry()
        unknown["fd"][0]["bv"] = 4
        result = self.evaluate([unknown])
        self.assertEqual(result["failures"]["unknown_boundary_frames"], 1)
        self.assertFalse(result["accepted"])

    def test_boundary_v3_requires_valid_renderer_draw(self):
        for renderer_draw in (None, -0.1, "invalid"):
            with self.subTest(renderer_draw=renderer_draw):
                record = telemetry()
                fields = boundary_fields()
                if renderer_draw is None:
                    del fields["rdw"]
                else:
                    fields["rdw"] = renderer_draw
                record["fd"][0].update(fields)
                result = self.evaluate([record])
                self.assertFalse(result["accepted"])

    def test_boundary_v2_does_not_require_renderer_draw(self):
        record = telemetry()
        fields = boundary_fields()
        fields["bv"] = 2
        del fields["rdw"]
        record["fd"][0].update(fields)
        result = self.evaluate([record])
        self.assertEqual(result["boundary_schema"]["versions"], [2])
        self.assertEqual(result["boundary_schema"]["detailed_frames"], 1)
        self.assertTrue(result["accepted"])

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

    def test_stable_triple_buffer_occupancy_is_not_pressure(self):
        record = telemetry()
        fields = boundary_fields()
        fields["qap"] = 2
        fields["qoa"] = 2
        record["fd"][0].update(fields)
        result = self.evaluate([record])
        self.assertEqual(result["classification_counts"]["submission_pressure"], 0)
        self.assertEqual(result["classification_counts"]["drawable_acquisition"], 1)

    def test_oldest_submission_age_three_is_pressure(self):
        record = telemetry()
        fields = boundary_fields()
        fields["qap"] = 2
        fields["qoa"] = 3
        record["fd"][0].update(fields)
        result = self.evaluate([record])
        self.assertEqual(result["classification_counts"]["submission_pressure"], 1)

    def test_classifies_intermediate_submit_maximum(self):
        record = telemetry()
        fields = boundary_fields()
        fields["aq"] = 0.1
        fields["ism"] = 1.5
        record["fd"][0].update(fields)
        result = self.evaluate([record])
        self.assertEqual(result["classification_counts"]["finish_or_submit"], 1)
        self.assertEqual(result["submission_calls"]["intermediate_submit_max"]["p50"], 1.5)

    def test_reports_pressure_correlations_and_p95_host_frames(self):
        record = telemetry()
        deliveries = []
        for index, host in enumerate((5, 6, 7, 20), start=1):
            delivery = dict(record["fd"][0])
            delivery.update(boundary_fields())
            delivery["i"] = index
            delivery["hc"] = host
            delivery["qap"] = index
            delivery["qoa"] = index
            delivery["aq"] = float(index)
            deliveries.append(delivery)
        record["fd"] = deliveries
        result = self.evaluate([record])
        self.assertEqual(result["boundary_schema"]["p95_host_threshold_ms"], 20)
        self.assertEqual(result["boundary_schema"]["p95_host_frames"], 1)
        self.assertEqual(result["boundary_schema"]["p95_host_frames_classified"], 1)
        self.assertGreater(result["pressure_correlations"]["after_poll"]["host"], 0)
        self.assertEqual(result["pressure_correlations"]["oldest_age"]["acquire"], 1)

    def test_distinguishes_renderer_unaccounted_from_over_accounting(self):
        parent_larger = telemetry()
        fields = boundary_fields()
        fields["rc"] = 6.9
        parent_larger["fd"][0].update(fields)
        result = self.evaluate([parent_larger])
        self.assertAlmostEqual(result["boundary_ms"]["renderer_unaccounted"]["p50"], 0.5)
        self.assertEqual(result["boundary_ms"]["renderer_closure_error"]["p50"], 0)
        children_larger = telemetry()
        fields = boundary_fields()
        fields["rc"] = 5.1
        children_larger["fd"][0].update(fields)
        result = self.evaluate([children_larger])
        self.assertEqual(result["boundary_ms"]["renderer_unaccounted"]["p50"], 0)
        self.assertAlmostEqual(result["boundary_ms"]["renderer_closure_error"]["p50"], 1.3)

    def test_v3_renderer_closure_nests_intermediate_work_in_draw(self):
        record = telemetry()
        fields = boundary_fields()
        fields.update({"rc": 6.4, "rdw": 0.1, "upl": 10, "en": 11, "sb": 12, "ium": 13, "ifm": 14, "ism": 15})
        record["fd"][0].update(fields)
        result = self.evaluate([record])
        self.assertEqual(result["boundary_ms"]["renderer_closure_error"]["p50"], 0)
        self.assertEqual(result["boundary_ms"]["renderer_unaccounted"]["p50"], 0)

    def test_v2_renderer_closure_uses_aggregate_submission_work(self):
        record = telemetry()
        fields = boundary_fields()
        fields.update({"bv": 2, "rc": 5.7, "rdw": 20, "upl": 0.5, "en": 0.2, "sb": 0.2})
        record["fd"][0].update(fields)
        result = self.evaluate([record])
        self.assertEqual(result["boundary_ms"]["renderer_closure_error"]["p50"], 0)
        self.assertEqual(result["boundary_ms"]["renderer_unaccounted"]["p50"], 0)

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

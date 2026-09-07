import copy
import hashlib
import json
import tempfile
import unittest
from pathlib import Path

from build_manifest import verify_build_manifest
from replay_inputs import batch_pipeline, submission_topology
from window_readiness import selected_window_readiness


def batch_pipeline_set(fmt=27):
    attributes = [dict(format=0x1D, offset=0, shader_location=0),
                  dict(format=0x1F, offset=8, shader_location=1),
                  dict(format=0x1D, offset=24, shader_location=2),
                  dict(format=0x20, offset=32, shader_location=3)]
    blends = [(0, 2, 6), (0, 2, 2), (0, 7, 6), (0, 5, 2)]
    pipelines = []
    for kind in range(2):
        for style in range(4):
            operation, src, dst = blends[style]
            blend = dict(operation=operation, src_factor=src, dst_factor=dst)
            pipelines.append(dict(
                known=True, format=fmt, vertex_stride=36, step_mode=1,
                attributes=copy.deepcopy(attributes), topology=4, strip_index=0,
                front_face=1, cull_mode=1, unclipped_depth=False, sample_count=1,
                sample_mask=0xffffffff, alpha_to_coverage=False, blend_enabled=True,
                blend_color=dict(blend), blend_alpha=dict(blend), write_mask=15))
    return pipelines


class WindowReadinessTests(unittest.TestCase):
    def test_retained_inputs_still_require_build_and_topology(self):
        vertex = dict(position_bits=[0, 0], color_bits=[0, 0, 0, 0], uv_bits=[0, 0], mode=0)
        payload = dict(version=11, batch_shader="captured shader",
                       batch_pipelines=batch_pipeline_set(),
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
                      span_count=1, encoder_spans=1,
                      draw_count=1, draws=[draw], draws_dropped=0, previous=dict(valid=False))
        report = selected_window_readiness(payload, record)
        self.assertEqual({item["field"] for item in report["missing_inputs"]},
                         {"source_manifest"})
        self.assertFalse(report["ready"])
        with tempfile.TemporaryDirectory() as directory:
            build = frozen_build(Path(directory), "captured shader")
            report = selected_window_readiness(payload, record, build)
            self.assertEqual(report["missing_inputs"], [])
            self.assertTrue(report["ready"])
            self.assertEqual(report["bundle_version"], 2)
            record["span_count"] = 2
            report = selected_window_readiness(payload, record, build)
            self.assertEqual({item["field"] for item in report["missing_inputs"]},
                             {"queue_topology"})
            record["span_count"] = 1
            (build / "ingot/gfx/batch.odin").write_text("BATCH_SHADER := `other`" + chr(10))
            report = selected_window_readiness(payload, record, build)
            self.assertEqual({item["field"] for item in report["missing_inputs"]},
                             {"source_manifest"})
        draw["neutral_texture"] = False
        report = selected_window_readiness(payload, record)
        self.assertIn("draws[0].texture", {item["field"] for item in report["missing_inputs"]})
        draw["neutral_texture"] = True
        payload["batch_pipelines"][0]["known"] = False
        report = selected_window_readiness(payload, record)
        self.assertIn("draws[0].pipeline_descriptor",
                      {item["field"] for item in report["missing_inputs"]})
        payload["version"] = 8
        report = selected_window_readiness(payload, record)
        self.assertTrue({"version", "draws[0].pipeline_descriptor"}.issubset(
            {item["field"] for item in report["missing_inputs"]}))


def frozen_build(directory, shader):
    source = directory / "ingot/gfx/batch.odin"
    source.parent.mkdir(parents=True)
    source.write_text("BATCH_SHADER := `" + shader + "`" + chr(10))
    digest = hashlib.sha256(source.read_bytes()).hexdigest()
    (directory / "prebuild-inputs.json").write_text(json.dumps(dict(
        sha256={"ingot/gfx/batch.odin": digest}, compiler=dict(sha256="c"),
        wgpu_archive=dict(sha256="w"), repositories={})))
    return directory


class BuildManifestTests(unittest.TestCase):
    def test_manifest_ties_shader_and_audit_to_files(self):
        with tempfile.TemporaryDirectory() as directory:
            build = frozen_build(Path(directory) / "timing-game-x", "s")
            summary = verify_build_manifest(dict(batch_shader="s"), build)
            self.assertEqual(summary["files"], 1)
            with self.assertRaises(ValueError):
                verify_build_manifest(dict(batch_shader="t"), build)
            library = build / "build.dylib"
            library.write_bytes(b"lib")
            capture = build / "capture.json"
            capture.write_bytes(b"cap")
            audit = {"timing-game-x/build.dylib": hashlib.sha256(b"lib").hexdigest()}
            (build / "identity-audit.json").write_text(json.dumps(dict(sha256=audit)))
            verify_build_manifest(dict(batch_shader="s"), build)
            with self.assertRaises(ValueError):
                verify_build_manifest(dict(batch_shader="s"), build, capture)
            audit["timing-game-x/capture.json"] = hashlib.sha256(b"cap").hexdigest()
            (build / "identity-audit.json").write_text(json.dumps(dict(sha256=audit)))
            summary = verify_build_manifest(dict(batch_shader="s"), build, capture)
            self.assertEqual(len(summary["audited"]), 2)
            library.write_bytes(b"changed")
            with self.assertRaises(ValueError):
                verify_build_manifest(dict(batch_shader="s"), build, capture)
            with self.assertRaises(ValueError):
                verify_build_manifest(dict(batch_shader="s"), Path(directory) / "missing")


class SubmissionTopologyTests(unittest.TestCase):
    def test_single_span_same_encoder_is_replayable(self):
        record = dict(span_count=1, encoder_spans=1, query_begin=0, encoder_id=4,
                      resolve_encoder_id=4, submit_ordinal=4, resolve_ordinal=4)
        self.assertEqual(submission_topology(dict(version=11), record)["spans"], 1)
        with self.assertRaises(ValueError):
            submission_topology(dict(version=10), record)
        for mutate in (dict(span_count=2), dict(encoder_spans=0), dict(query_begin=2),
                       dict(query_begin=1), dict(resolve_encoder_id=5),
                       dict(resolve_ordinal=3), dict(span_count=2, encoder_spans=2),
                       dict(encoder_id=0)):
            with self.assertRaises(ValueError):
                submission_topology(dict(version=11), dict(record, **mutate))


class BatchPipelineTests(unittest.TestCase):
    def setUp(self):
        self.payload = dict(version=11, batch_pipelines=batch_pipeline_set())
        self.record = dict(format=27)

    def test_selected_descriptor_matches_contract(self):
        entry = batch_pipeline(self.payload, dict(pipeline_kind=0, pipeline_style=2),
                               self.record)
        self.assertEqual(entry["blend_color"]["src_factor"], 7)
        entry = batch_pipeline(self.payload, dict(pipeline_kind=1, pipeline_style=1),
                               self.record)
        self.assertEqual(entry["blend_color"]["dst_factor"], 2)

    def test_custom_style_and_wrong_format_are_rejected(self):
        with self.assertRaises(ValueError):
            batch_pipeline(self.payload, dict(pipeline_kind=0, pipeline_style=3), self.record)
        with self.assertRaises(ValueError):
            batch_pipeline(self.payload, dict(pipeline_kind=0, pipeline_style=0),
                           dict(format=22))
        with self.assertRaises(ValueError):
            batch_pipeline(self.payload, dict(pipeline_kind=2, pipeline_style=0), self.record)

    def test_descriptor_deviations_are_rejected(self):
        draw = dict(pipeline_kind=0, pipeline_style=0)
        for mutate in (
                lambda entry: entry.__setitem__("vertex_stride", 40),
                lambda entry: entry["attributes"][1].__setitem__("offset", 12),
                lambda entry: entry.__setitem__("cull_mode", 3),
                lambda entry: entry.__setitem__("sample_count", 4),
                lambda entry: entry.__setitem__("blend_enabled", False),
                lambda entry: entry["blend_alpha"].__setitem__("dst_factor", 2),
                lambda entry: entry.__setitem__("write_mask", 7),
                lambda entry: entry.__setitem__("unclipped_depth", True),
                lambda entry: entry.__setitem__("format", True)):
            payload = copy.deepcopy(self.payload)
            mutate(payload["batch_pipelines"][0])
            with self.assertRaises(ValueError):
                batch_pipeline(payload, draw, self.record)
        payload = copy.deepcopy(self.payload)
        payload["batch_pipelines"].pop()
        with self.assertRaises(ValueError):
            batch_pipeline(payload, draw, self.record)

    def test_missing_evidence_is_not_ready(self):
        report = selected_window_readiness({}, {})
        self.assertFalse(report["ready"])
        fields = {entry["field"] for entry in report["missing_inputs"]}
        self.assertTrue({"draws", "clear_bits_known", "source_manifest",
                         "queue_topology"}.issubset(fields))
        self.assertFalse(selected_window_readiness({"version": 11}, {"span_count": 1})["ready"])

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

import json
import tempfile
import unittest
from pathlib import Path

from evaluate_replay import candidate_passes, evaluate_run, load_run
from export_replay_bundle import export_bundle
from test_window_readiness import frozen_build


def run_records(mode, ticks, prior_kind="mapped"):
    records = [{"kind": "header", "mode": mode, "frame": 11, "iterations": len(ticks)}]
    prior = (0, 0)
    for index, (begin, end) in enumerate(ticks):
        if end == 0:
            klass = "zero_end"
        elif end < begin:
            klass = "reversed_nonzero"
        else:
            klass = "ordered"
        record = {"kind": "sample", "iteration": index, "slot": index % 2, "class": klass,
                  "prior_begin": prior[0], "prior_end": prior[1], "prior_kind": prior_kind}
        if mode == "webgpu_pinned_replay":
            record.update(begin=begin, end=end, status=1, mapped=True)
        else:
            record.update(gpu_begin=begin, gpu_end=end, status=4)
        records.append(record)
        prior = (begin, end)
    records.append({"kind": "footer", "submits": len(ticks), "command_failures": 0,
                    "drained": True})
    return records


class EvaluateReplayTests(unittest.TestCase):
    def test_stale_by_one_pass_signature_is_counted(self):
        base = 1_000_000_000
        period = 8_500_000
        duration = 197_000
        ticks = [(base, 0)]
        for index in range(1, 6):
            begin = base + index * period
            ticks.append((begin, ticks[index - 1][0] + duration))
        summary = evaluate_run(run_records("gpu_resolve", ticks))
        self.assertEqual(summary["classes"]["zero_end"], 1)
        self.assertEqual(summary["classes"]["reversed_nonzero"], 5)
        self.assertEqual(summary["stale_by_one_pass"], 0)
        self.assertFalse(candidate_passes(summary))
        ticks.append((base + 6 * period, base + 6 * period + duration))
        summary = evaluate_run(run_records("gpu_resolve", ticks))
        self.assertEqual(summary["median_duration_ns"], duration)
        self.assertEqual(summary["stale_by_one_pass"], 5)
        self.assertFalse(candidate_passes(summary))

    def test_ordered_run_with_first_use_zero_passes(self):
        ticks = [(100, 0), (200, 300), (400, 520), (600, 700)]
        summary = evaluate_run(run_records("webgpu_pinned_replay", ticks))
        self.assertEqual(summary["classes"]["ordered"], 3)
        self.assertTrue(candidate_passes(summary))
        ticks.append((900, 0))
        summary = evaluate_run(run_records("webgpu_pinned_replay", ticks))
        self.assertFalse(candidate_passes(summary))

    def test_incomplete_run_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "run.jsonl"
            path.write_text(json.dumps({"kind": "header"}) + "\n")
            with self.assertRaises(ValueError):
                load_run(path)


def frozen_capture_payload():
    vertex = {"position_bits": [0, 0], "color_bits": [0, 0, 0, 1065353216],
              "uv_bits": [0, 0], "mode": 0}
    pipeline = {"known": True, "format": 27, "vertex_stride": 36, "step_mode": 1,
                "attributes": [{"format": 29, "offset": 0, "shader_location": 0},
                               {"format": 31, "offset": 8, "shader_location": 1},
                               {"format": 29, "offset": 24, "shader_location": 2},
                               {"format": 32, "offset": 32, "shader_location": 3}],
                "topology": 4, "strip_index": 0, "front_face": 1, "cull_mode": 1,
                "unclipped_depth": False, "sample_count": 1, "sample_mask": 0xffffffff,
                "alpha_to_coverage": False, "blend_enabled": True,
                "blend_color": {"operation": 0, "src_factor": 2, "dst_factor": 6},
                "blend_alpha": {"operation": 0, "src_factor": 2, "dst_factor": 6},
                "write_mask": 15}
    draw = {"neutral_texture": True, "atlas_id": 0, "atlas_upload_count": 0, "atlas_filter": 0,
            "atlas_known": False, "geometry_id": 1, "projection": [0, 0, 1, 0],
            "projection_bits": [978111693, 985008993, 1065353216, 0],
            "projection_known": True, "path": 1, "known": True, "indexed": True, "count": 3,
            "instances": 1, "shader_id": 0, "pipeline_kind": 0, "pipeline_style": 0,
            "scissor": [0, 0, 2560, 1440]}
    record = {"epoch": 1, "frame": 2, "generation": 2, "map_request": 2, "encoder_id": 2,
              "submit_ordinal": 2, "resolve_ordinal": 2, "resolve_encoder_id": 2,
              "begin_tick": 500, "end_tick": 400,
              "previous": {"valid": True, "epoch": 1, "frame": 1, "generation": 1,
                           "begin_tick": 100, "end_tick": 0},
              "draw_count": 1, "draws": [draw], "draws_dropped": 0, "query_begin": 0,
              "slot_index": 0, "span_count": 1, "encoder_spans": 1, "load": 2, "store": 1,
              "label": {"bytes": [119, 105, 110, 100, 111, 119] + [0] * 26, "length": 6},
              "width": 2560, "height": 1440, "format": 27, "depth_format": 0,
              "depth_load": 0, "depth_store": 0, "depth_clear": 0.0,
              "depth_read_only": False, "color_clear": [0, 0, 0, 1],
              "color_clear_bits": [0, 0, 0, 4607182418800017408], "depth_clear_bits": 0,
              "clear_bits_known": True, "sample_count": 1, "callback_status": 1,
              "collection_id": 2}
    return {"version": 11, "batch_shader": "@vertex fn vs_main() {}",
            "batch_pipelines": [pipeline] * 8, "atlas_count": 0, "atlas_uploads": [],
            "atlas_bytes": [], "atlas_dropped": 0, "atlas_dropped_bytes": 0,
            "geometry": [{"vertices": [vertex] * 3, "indices": [0, 1, 2]}],
            "geometry_dropped": 0, "failures": [record], "dropped": 0,
            "encoder_overflow": 0, "missing_encoder": 0, "categories": [],
            "category_overflow": 0}


def export_from_frozen_build(payload, directory):
    build = frozen_build(Path(directory) / "timing-game-x", payload["batch_shader"])
    bundle = Path(directory) / "bundle"
    return export_bundle(payload, 0, bundle, build_dir=build), bundle


class ExportBundleTests(unittest.TestCase):
    def test_bundle_contains_exact_bytes_and_topology(self):
        payload = frozen_capture_payload()
        with tempfile.TemporaryDirectory() as directory:
            manifest, bundle = export_from_frozen_build(payload, directory)
            self.assertEqual((bundle / "draw0.vertices.bin").stat().st_size, 36 * 3)
            self.assertEqual((bundle / "draw0.indices.bin").read_bytes(),
                             b"\x00\x00\x00\x00\x01\x00\x00\x00\x02\x00\x00\x00")
            self.assertEqual(manifest["draws"][0]["fragment_entry"], "fs_ui")
            self.assertIsNone(manifest["draws"][0]["atlas"])
            self.assertEqual(manifest["attachment"]["color_clear_bits"][3],
                             4607182418800017408)
            self.assertEqual(manifest["topology"]["spans"], 1)
            self.assertEqual(json.loads((bundle / "manifest.json").read_text())["frame"], 2)

    def test_dropped_draws_and_unready_records_are_rejected(self):
        payload = frozen_capture_payload()
        payload["failures"][0]["draws_dropped"] = 1
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(ValueError):
                export_from_frozen_build(payload, directory)
        payload = frozen_capture_payload()
        payload["failures"][0]["clear_bits_known"] = False
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(ValueError):
                export_from_frozen_build(payload, directory)
        payload = frozen_capture_payload()
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(ValueError):
                export_bundle(payload, 0, Path(directory) / "bundle")


if __name__ == "__main__":
    unittest.main()

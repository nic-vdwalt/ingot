import json
import tempfile
import unittest
from pathlib import Path

from evaluate_replay import (candidate_passes, evaluate_run, evaluate_sweep,
                             mechanism_verdict, publication_summary)
from evaluate_replay import load_run
from evaluate_metal_trace import evaluate_trace
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

    def test_per_index_unique_reuse_and_all_stage_staleness(self):
        records = [{"kind": "header", "mode": "gpu_resolve", "experiment": "unique_indices",
                    "iterations": 65, "gap_dispatches": 0}]
        for iteration in range(65):
            index = iteration * 2 % 128
            prior = 3000 if iteration == 64 else 0
            records.append({"kind": "sample", "iteration": iteration, "class": "zero_end",
                            "gpu_begin": 0, "gpu_end": prior, "indices": [index, index + 1],
                            "gpu_samples": [0, prior], "cpu_samples": [2000 + iteration, 3000 + iteration],
                            "prior_cpu_samples": [2000, 3000] if iteration == 64 else [0, 0]})
        records.append({"kind": "footer", "drained": True, "command_failures": 0})
        summary = evaluate_run(records)
        self.assertEqual(summary["first_use_zero"], 64)
        self.assertEqual(summary["stale_by_k_passes"]["64"], 1)
        self.assertEqual(summary["per_index"]["end"]["stale_prior_index"], 1)

        records = [{"kind": "header", "experiment": "all_stages", "iterations": 1},
                   {"kind": "sample", "iteration": 0, "class": "ordered",
                    "gpu_begin": 10, "gpu_end": 20, "indices": [0, 1, 2, 3],
                    "gpu_samples": [10, 11, 12, 20], "cpu_samples": [10, 21, 22, 23],
                    "prior_cpu_samples": [0, 11, 12, 20]},
                   {"kind": "footer", "drained": True, "command_failures": 0}]
        summary = evaluate_run(records)
        self.assertEqual(summary["per_index"]["start_of_vertex"]["matches_cpu"], 1)
        self.assertEqual(summary["per_index"]["end_of_vertex"]["stale_prior_index"], 1)
        self.assertEqual(summary["per_index"]["start_of_fragment"]["stale_prior_index"], 1)
        self.assertEqual(summary["per_index"]["end_of_fragment"]["stale_prior_index"], 1)

    def test_publication_and_gap_summaries(self):
        records = [{"kind": "header"},
                   {"kind": "publication", "first_new_end_host_ns": 130,
                    "end_sample_ns": 100, "gpu_end_ns": 120, "completed_host_ns": 140},
                   {"kind": "publication", "first_new_end_host_ns": 250,
                    "end_sample_ns": 200, "gpu_end_ns": 240, "completed_host_ns": 245},
                   {"kind": "footer"}]
        summary = publication_summary(records)
        self.assertEqual(summary["sample_to_publication_ns_median"], 40)
        self.assertEqual(summary["at_or_after_gpu_end"], 2)
        self.assertEqual(summary["before_completion"], 1)
        gap = run_records("gpu_resolve", [(100, 0), (200, 300)])
        gap[0].update(experiment="gap_2", gap_dispatches=2)
        gap[1]["gap_gpu_ns"] = 900
        gap[2]["gap_gpu_ns"] = 1100
        rows = evaluate_sweep([gap])
        self.assertEqual(rows[0]["measured_gap_ns_median"], 1000)

    @staticmethod
    def mechanism_summary(experiment, reversed_total=0, ordered=100, samples=100,
                          gap_dispatches=0, measured_gap_ns_median=None):
        return {"experiment": experiment, "reversed_total": reversed_total, "samples": samples,
                "classes": {"ordered": ordered}, "gap_dispatches": gap_dispatches,
                "measured_gap_ns_median": measured_gap_ns_median,
                "first_use_zero": 128, "publication": {"observed": 100,
                "at_or_after_gpu_end": 100}}

    def test_mechanism_verdict_h_a(self):
        make = self.mechanism_summary
        summaries = [make("publication_latency", 99, 1),
                     make("gap_0", 99, 1), make("gap_1", 0, 100, gap_dispatches=1,
                                                measured_gap_ns_median=900_000),
                     make("tracked_dependency", 99, 1),
                     make("deferred_enqueued"), make("deferred_scheduled"),
                     make("deferred_completed"), make("unique_indices")]
        verdict = mechanism_verdict(summaries, {"blit_before_fragment_fraction": 0})
        self.assertEqual(verdict["mechanism"], "H-A")
        self.assertEqual(verdict["latency_upper_bound_ns"], 900_000)

    def test_mechanism_verdict_h_b(self):
        make = self.mechanism_summary
        summaries = [make("publication_latency", 99, 1),
                     make("gap_16", 99, 1, gap_dispatches=16, measured_gap_ns_median=10_000_000),
                     make("gap_32", 99, 1, gap_dispatches=32, measured_gap_ns_median=20_000_000),
                     make("tracked_dependency", 99, 1),
                     make("deferred_enqueued", 99, 1), make("deferred_scheduled", 99, 1),
                     make("deferred_completed"), make("unique_indices")]
        verdict = mechanism_verdict(summaries, {"blit_before_fragment_fraction": 0})
        self.assertEqual(verdict["mechanism"], "H-B")
        self.assertEqual(verdict["candidate"], "completed_handler_resolve")

    def test_mechanism_verdict_h_c(self):
        make = self.mechanism_summary
        summaries = [make("tracked_dependency"), make("deferred_enqueued"),
                     make("deferred_scheduled"), make("deferred_completed"), make("unique_indices")]
        verdict = mechanism_verdict(summaries, {"blit_before_fragment_fraction": 0.75})
        self.assertEqual(verdict["mechanism"], "H-C")

    def test_mechanism_verdict_h_d_and_inconclusive(self):
        summary = self.mechanism_summary("unique_indices")
        summary["first_use_zero"] = 1
        self.assertEqual(mechanism_verdict([summary])["mechanism"], "H-D")
        verdict = mechanism_verdict([self.mechanism_summary("unique_indices")])
        self.assertEqual(verdict["mechanism"], "inconclusive")
        self.assertIn("metal_system_trace", verdict["missing"])

    def test_metal_trace_joins_fragment_and_resolve_by_command_buffer(self):
        trace = """<?xml version="1.0"?><trace-query-result><node><row>
<start-time>100</start-time><duration>50</duration><gpu-channel-name>Fragment</gpu-channel-name>
<gpu-frame-number>1</gpu-frame-number><duration>0</duration><metal-nesting-level>0</metal-nesting-level>
<formatted-label fmt="mechanism.render.7:mechanism.render"/><gpu-state>Active</gpu-state>
<connection-uuid64>1</connection-uuid64><render-buffer-depth>0</render-buffer-depth><process/>
<metal-device-name>M2 Max</metal-device-name><metal-object-label/><formatted-label/><size-in-bytes>0</size-in-bytes>
<metal-command-buffer-id>42</metal-command-buffer-id><metal-command-buffer-id>43</metal-command-buffer-id><uint64>1</uint64>
</row><row>
<start-time>151</start-time><duration>5</duration><gpu-channel-name>Compute</gpu-channel-name>
<gpu-frame-number>1</gpu-frame-number><duration>0</duration><metal-nesting-level>0</metal-nesting-level>
<formatted-label fmt="mechanism.render.7:mechanism.resolve"/><gpu-state>Active</gpu-state>
<connection-uuid64>1</connection-uuid64><render-buffer-depth>0</render-buffer-depth><process/>
<metal-device-name>M2 Max</metal-device-name><metal-object-label/><formatted-label/><size-in-bytes>0</size-in-bytes>
<metal-command-buffer-id>42</metal-command-buffer-id><metal-command-buffer-id>44</metal-command-buffer-id><uint64>2</uint64>
</row></node></trace-query-result>"""
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "trace.xml"
            path.write_text(trace)
            summary = evaluate_trace(path)
        self.assertEqual(summary["pairs"], 1)
        self.assertEqual(summary["blit_before_fragment_end"], 0)
        self.assertEqual(summary["median_resolve_start_minus_fragment_end_ns"], 1)


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

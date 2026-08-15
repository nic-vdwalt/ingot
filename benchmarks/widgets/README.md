# Scalable Widget Benchmark

This suite compares headless CPU work for Ingot Fit, Dear ImGui, and egui with pinned revisions,
deterministic workloads, randomized process order, correctness validation, and raw JSONL output.
It does not produce an overall score. The Ingot adapter uses only the public `ingot:fit` package;
its high-level description, measure, layout, interaction, paint, and semantic work differs from the
other adapters' fixed-placement paths.

The latest checked-in direct-`ingot:ui` evidence remains the
[2026-07-29 Apple M2 Max core run](results/2026-07-29-m2-max-core.md). Fit results are a new
methodology and must not be compared numerically with that baseline. Cross-framework results are
workload-specific headless measurements, not native application or GPU rankings.

## Requirements

- Odin revision pinned in `ODIN_VERSION`
- Python 3
- Rust 1.90.0 with Cargo
- A C++17 compiler
- Git and network access for the pinned Dear ImGui checkout

The runner verifies the bundled font hash and Dear ImGui revision. Cargo uses the checked-in lockfile.
Generated binaries, dependency checkouts, and Cargo targets are ignored.

## Run

From the repository root:

```sh
python3 benchmarks/widgets/runner/bench.py build
python3 benchmarks/widgets/runner/bench.py smoke
python3 benchmarks/widgets/runner/bench.py run --output /tmp/widget-results.jsonl
python3 benchmarks/widgets/runner/bench.py validate --output /tmp/widget-results.jsonl
python3 benchmarks/widgets/report/report.py /tmp/widget-results.jsonl \
  --output-dir /tmp/widget-report
```

A full run uses 300 warm-up frames, 2,000 measured frames, and seven fresh-process repetitions for
every configured core case. Restrict development runs with `--framework`, `--workload`, `--scale`,
`--warmup`, `--frames`, or `--repetitions`.

Workloads may declare a `frameworks` list and additional `framework_scales`. Shared scales run on all
eligible adapters and participate in checksum validation; framework scales characterize larger cases
without implying parity. Fit uses caller-provided bounded description storage with an 8,192-node hard
maximum, so shared cases never exceed that contract. Ingot-only profiling cases isolate repeated,
stable-unique, and changing-unique labels; inactive and active inputs; control construction; paired
semantics-disabled/enabled buttons; and flow layout.

`complex_dashboard` submits ten elements per row: a unique title, status, checkbox, slider, persistent
text input, action button, and four data cells. Its fixed geometry isolates deterministic UI
construction and finalization costs. It does not model responsive layout, scrolling, application
state updates, native event handling, accessibility hosts, presentation, or GPU execution.

`complex_dashboard` is the representative warm integrated workload. `capacity` characterizes bounded
fixed-storage overflow. Ingot paint lists currently use fixed command and text arrays, so there is no
true forced-growth case until the bounded-reservation storage work lands; growth telemetry must remain
zero in Phase 2.

`layout_flow` is an Ingot-only geometry workload. It lays out 32–1,024 explicitly measured items with
varying dimensions, validates a deterministic geometry checksum, and emits no paint or semantic output.
It isolates flow-layout CPU cost and scaling; it is not a Clay comparison and does not measure text
measurement, rendering, input, accessibility, or application frame time.

For two independent runs:

```sh
python3 benchmarks/widgets/report/reproducibility.py \
  /tmp/widget-results-a.jsonl /tmp/widget-results-b.jsonl
```

## Interpretation

The Ingot result layer is `fit`; competitor records retain their `core` layer. Ingot build timing covers
Fit description construction. Fit also reports measurement, layout/render, and actual frame-finalize
subphases. Finalization remains their compatibility aggregate, and total timing directly spans the
complete headless Fit frame. Output counts and bounded-drop diagnostics invalidate nominal Ingot runs.
Dear ImGui accessibility is unsupported; egui does not claim native AccessKit integration without an
`eframe` host.

Native GPU, presentation, idle-power, startup, RSS, and wakeup measurements require equivalent native
hosts and dated platform evidence. They must not be inferred from these core results. Ingot renderer
telemetry exposes CPU encoding, queue-submit, presentation-call, upload, batch, and arena statistics for
such native runs; these are CPU-call timings, not GPU timestamp or scan-out latency.

Before comparing machines, set environment disclosures used by the runner:

```sh
export INGOT_BENCH_DISPLAY='1280x720@60 scale=1'
export INGOT_BENCH_POWER_MODE='AC, low-power-mode=off'
```

Retain the raw JSONL, `manifest.json`, generated aggregate files, hardware details, OS revision, display
configuration, thermal/power state, and framework/compiler revisions with every published report.

For development evidence, use at least 100 warm-up and 500 measured frames with five fresh processes.
Accepted Phase 2 evidence uses the default 300 warm-up, 2,000 measured frames, and seven repetitions,
and reports total, build, and finalization median/p95 values. Optimization evidence compares complete
frames from matching environments. Internal Fit phases identify causes and are not compared with
competitor build phases.

# Scalable Widget Benchmark

This suite compares headless core CPU work for Ingot, Dear ImGui, and egui with pinned revisions,
deterministic geometry, fixed workloads, randomized process order, correctness validation, and raw
JSONL output. It does not produce an overall score.

The latest checked-in evidence is the
[2026-07-26 Apple M2 Max core run](results/2026-07-26-m2-max-core.md). Ingot was competitive with Dear
ImGui in that run: Ingot led repeated labels, mixed forms, and a virtualized list, while Dear ImGui led
the button grid, full list, table-like, and churn cases. egui used materially more core CPU in these
fixed-geometry adapters. Treat those as workload-specific headless results, not native application or
GPU rankings.

## Requirements

- Odin `dev-2026-06:285f6d87b`
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

`complex_dashboard` submits ten elements per row: a unique title, status, checkbox, slider, persistent
text input, action button, and four data cells. Its fixed geometry isolates deterministic UI
construction and finalization costs. It does not model responsive layout, scrolling, application
state updates, native event handling, accessibility hosts, presentation, or GPU execution.

For two independent runs:

```sh
python3 benchmarks/widgets/report/reproducibility.py \
  /tmp/widget-results-a.jsonl /tmp/widget-results-b.jsonl
```

## Interpretation

The implemented primary layer is headless core CPU measurement. Build and finalization timings are
separate. Output counts and bounded-drop diagnostics invalidate nominal Ingot runs; capacity cases are
reported separately. Dear ImGui accessibility is unsupported. The egui adapter exercises core semantic
widget construction but does not claim native AccessKit integration without an `eframe` host.

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

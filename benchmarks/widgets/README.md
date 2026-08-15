# Scalable Widget Benchmark

This suite compares headless CPU work for Ingot Fit, direct Ingot UI, Dear ImGui, and egui with
pinned revisions, deterministic workloads, randomized process order, correctness validation, and raw
JSONL output. It does not produce an overall score. The Ingot adapter has two public-package paths.
`--ingot-layer=fit` builds a transient Fit description, measures it, resolves layout, renders through
`ingot:ui`, and finalizes the frame. `--ingot-layer=ui` submits resolved rectangles directly through
`ingot:ui` and finalizes the same core frame. Dear ImGui and egui retain fixed-placement core adapters.

The [2026-07-29 Apple M2 Max core run](results/2026-07-29-m2-max-core.md) remains historical
fixed-geometry evidence. Current Fit/UI claims use same-revision paired records instead of comparing
numerically with that older run. Cross-framework results are workload-specific headless measurements,
not native application or GPU rankings.

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
every configured core case. Restrict development runs with `--framework`, `--ingot-layer`,
`--workload`, `--scale`, `--warmup`, `--frames`, or `--repetitions`.

### Ingot package modes

| Mode | Caller supplies | Timed complete frame includes | Intended comparison |
|---|---|---|---|
| `fit` | Widget hierarchy, sizing constraints, caller-owned state | Description construction, intrinsic measurement, size resolution, placement, interaction, paint, optional semantics, core finalization | Ergonomic high-level API cost |
| `ui` | Explicit fixed rectangles, identities, caller-owned state | Direct widget interaction/paint, optional semantics, core finalization | Fixed-placement core comparison with Dear ImGui |

Fit is implemented on top of `ingot:ui`; it is not expected to match direct UI latency because it
performs work the direct caller has already resolved. The measured Fit/UI delta can include transient
prepared-node construction, tree traversal, intrinsic measurement for non-fixed leaves, layout and
placement, prepared-node rendering and activation aggregation, and bounded bookkeeping. Both paths
share core interaction, paint recording, text backend and cache policy, semantics, route finalization,
and frame lifetime work. Phase telemetry attributes the total delta but is not primitive-equivalent
accounting and independently summarized phase medians are not additive.

Run one Ingot mode or both modes with competitors:

```sh
python3 benchmarks/widgets/runner/bench.py run --framework ingot --ingot-layer ui
python3 benchmarks/widgets/runner/bench.py run --framework all --ingot-layer both
```

Collect paired Fit/UI evidence:

```sh
python3 benchmarks/widgets/runner/ingot_layers.py \
  --binary benchmarks/widgets/build/ingot-widget-bench \
  --case complex_dashboard:50 \
  --warmup 300 --frames 2000 --repetitions 7 \
  --output /tmp/widget-ingot-layers.jsonl
python3 benchmarks/widgets/report/ingot_layers.py \
  /tmp/widget-ingot-layers.jsonl --output-dir /tmp/widget-ingot-layers-report
```

Collect paired direct-UI/ImGui complete-frame evidence:

```sh
python3 benchmarks/widgets/runner/ui_imgui.py \
  --ui-binary benchmarks/widgets/build/ingot-widget-bench \
  --imgui-binary benchmarks/widgets/build/imgui-widget-bench \
  --case complex_dashboard:250 \
  --warmup 300 --frames 2000 --repetitions 7 \
  --output /tmp/widget-ui-imgui.jsonl
python3 benchmarks/widgets/report/ui_imgui.py \
  /tmp/widget-ui-imgui.jsonl --output-dir /tmp/widget-ui-imgui-report
```

The August 15 direct-UI optimization pass added bounded disabled-subsystem, input-route, interaction,
text-measurement, and paint-recording fast paths. It deliberately did not snapshot style tokens at frame
begin because scale and metrics can change while a frame is open. Pane culling remains paint-only and
active only inside an established pane band; interaction, state, focus, semantics, and active IME work
continue for offscreen controls.

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

The `prepared_*` workloads expose Fit topology directly: fixed versus intrinsic flat grids, container-
dense rows, bounded depth, width-dependent wrapping, mixed tracks, and generic fallback. Telemetry
records phase time, description topology, node and child visits, measure callbacks, direct specialization,
and fallback work. The fixed-grid direct path is expected to report zero generic measure/resolve visits.
Complete-frame samples remain authoritative because telemetry clocks and counters are diagnostic work.

Paint clipping does not avoid description, layout, interaction, or semantic work. `list_virtual` instead
reduces the declared rows to the visible range plus bounded overscan; its prepared-node count must remain
constant as logical size grows.

For two independent runs:

```sh
python3 benchmarks/widgets/report/reproducibility.py \
  /tmp/widget-results-a.jsonl /tmp/widget-results-b.jsonl
```

## Interpretation

Ingot records use `fit` or `ui`; competitor records retain their `core` layer. Fit build timing covers
description construction and reports measurement, layout/render, and actual frame-finalize subphases.
Direct UI build timing covers fixed-rectangle widget submission. Both Ingot total timings directly span
the complete headless frame. Output counts and bounded-drop diagnostics invalidate nominal Ingot runs.
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
direct-UI or competitor build phases. Use complete `frame` versus complete `frame` for Fit/UI. Dear
ImGui requires a fresh complete boundary from `NewFrame` through `Render`; historical build-only
values must not be divided into a Fit complete-frame median.

`fixed_leaf_measure_skips` counts leaves whose own fixed width and height avoid intrinsic callbacks.
`measure_cache_policy_bypasses` proves the backend-cache-disabled A/B arm executed. `input_active`
keeps exactly one field focused after a deterministic pre-measure activation sequence. Optimization
acceptance uses randomized adjacent fresh-process pairs and complete `frame` medians; Fit phases and
telemetry attribute a result but do not replace complete-frame evidence.

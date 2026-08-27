# Performance evidence

Ingot maintains two separate benchmark scopes. They must not be combined into a
single ranking or headline.

## Headless UI-core suite

[`benchmarks/widgets/README.md`](../benchmarks/widgets/README.md) measures
bounded CPU work for Fit, direct UI, and pinned competitor adapters. It excludes
native event handling, real text rasterization, GPU execution, presentation,
startup, RSS, idle power, and accessibility hosts. Existing dated results retain
that scope.

## End-to-end application suite

`benchmarks/end_to_end/manifest.json` defines canonical complete-application
workloads. Build a fixture with:

```sh
python3 scripts/benchmark-end-to-end.py build \
  --workload gallery \
  --output /tmp/ingot-gallery-bench
```

Create an evidence skeleton for an operator-controlled run with all environment
fields supplied:

```sh
INGOT_BENCH_BACKEND=Metal \
INGOT_BENCH_DISPLAY=2560x1440@120Hz \
INGOT_BENCH_DPI=2 \
INGOT_BENCH_GPU='Apple M2 Max' \
INGOT_BENCH_DRIVER='macOS 15.6.1' \
INGOT_BENCH_POWER_MODE='AC; low-power off' \
INGOT_BENCH_PRESENT_MODE=Fifo \
python3 scripts/benchmark-end-to-end.py run \
  --workload gallery \
  --output /tmp/ingot-gallery-evidence.json
```

`run` currently builds and fingerprints the instrumented fixture; it does not
fabricate runtime measurements. Dated runtime collection must add observations
from a controlled native or browser run before publication.

## Required published fields

Every report records:

- exact Ingot and Odin revisions;
- OS, architecture, GPU, driver, backend, display, DPI, refresh and presentation
  mode;
- window size, warm-up, measured frames, repetitions, run order, power mode and
  thermal disclosure;
- p50, p95, p99 and maximum for complete frame time;
- UI build/layout, paint generation, WebGPU encoding, queue submission and
  presentation-call CPU time when instrumentation is enabled;
- GPU timestamps only where the backend actually supplies timestamp queries;
- startup-to-first-present, RSS/working set, long-run growth, idle CPU/wakeups,
  binary/WASM size, and resource-capacity peaks where platform tools permit;
- bounded raw JSONL, aggregate JSON/CSV, artifact checksums, and the report
  generator revision.

A CPU duration around `QueueSubmit` or `Present` is not GPU execution time. A
requested uncapped mode is not reported as uncapped until the selected backend
and observed presentation behavior prove it. Missing measurements remain
missing rather than inferred.

## Canonical workloads

- `hello`: startup and minimum complete-frame floor.
- `gallery`: complete widget ceiling.
- `virtual-list`: 5,000 and 100,000 logical rows with fixed visible work.
- `table`: 5,000 rows with interaction and semantics.
- `idle`: five minutes without input to measure sleeping behavior.

Resize, DPI transition, overlay stacking, atlas saturation, long scalar text,
and context recreation are stress scenarios, not interchangeable steady-state
workloads.

## Publication rule

Commit raw evidence under `benchmarks/end_to_end/results/` only when it includes
the complete machine manifest and durable checksums. Temporary local paths are
not publication evidence. Compare two fresh collections before accepting a
regression baseline, and state the tolerance used.

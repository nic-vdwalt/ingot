# Direct UI Performance Restoration — Development Evidence

This is local development evidence, not a universal framework ranking. It measures headless CPU work on an Apple M2 Max with complete-frame boundaries.

## Method

- 300 warm-up frames.
- 2,000 measured frames.
- Seven adjacent fresh-process pairs per workload.
- Matching state checksum, submitted widgets, visible widgets, valid status, and no dropped output.
- Baseline binary captured before the optimization edits; candidate binary captured after them.
- Local Odin differs from the repository pin, so these numbers should not be presented as pinned-toolchain release evidence.

## Baseline vs optimized direct UI

| Workload | Scale | Baseline frame median | Optimized frame median | Candidate/baseline | Improved pairs |
|---|---:|---:|---:|---:|---:|
| `labels_repeated` | 1,000 | 39.92 µs | 35.71 µs | 0.8924× | 6/7 |
| `labels_unique` | 1,000 | 58.50 µs | 52.54 µs | 0.8982× | 6/7 |
| `checkbox_only` | 250 | 69.38 µs | 42.62 µs | 0.6168× | 7/7 |
| `slider_only` | 250 | 43.46 µs | 44.21 µs | 0.8412× paired median ratio | 6/7 |
| `button_only` | 250 | 54.58 µs | 34.25 µs | 0.6279× | 7/7 |
| `input_inactive` | 250 | 45.88 µs | 41.38 µs | 0.9028× | 6/7 |
| `complex_dashboard` | 250 | 289.04 µs | 220.29 µs | 0.7626× | 7/7 |

The process-paired ratio is authoritative when aggregate medians and pair ratios differ. Raw summary: `/tmp/widget-ui-optimization-paired-summary.json`.

## Optimized direct UI vs Dear ImGui

| Workload | Scale | UI frame median | ImGui frame median | UI/ImGui | Paired 95% CI |
|---|---:|---:|---:|---:|---:|
| `complex_dashboard` | 250 | 220.27 µs | 206.46 µs | 1.0656× | 1.0476–1.1330 |

The optimized direct path is substantially closer but remains slower in this run. Raw JSONL: `/tmp/widget-ui-imgui-optimized.jsonl`; generated report: `/tmp/widget-ui-imgui-optimized-report/report.md`.

## Accepted implementation changes

- Disabled semantic calls return before registry work only when no enabled focus target can be registered.
- Empty route state avoids bounded-array copying and z lookup.
- Strictly idle interactions return the exact hover-only result.
- Backend text measurement uses an eight-entry, 64-byte inline L0 ahead of the bounded map.
- Paint commands receive tier/z metadata once, and lifetime peaks are updated at frame finalization.
- Pane culling skips paint for checkboxes, sliders, and inactive text inputs while retaining interaction, state, focus, semantics, and active IME work.

## Rejected or deferred changes

- Style/token snapshots were not added. Scale and exposed metrics can change during an open frame, so an immutable begin-time snapshot would change behavior.
- Screen-wide default culling was not added. Non-pane callers retain their existing output contract.
- The backend measurement cache was not disabled; the runtime policy remains enabled and the hot repeated-key path was optimized instead.

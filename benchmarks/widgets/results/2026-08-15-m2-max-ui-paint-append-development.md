# Direct UI In-Place Paint Append — Development Evidence

This is local development evidence from an Apple M2 Max on macOS 15.6.1. It measures headless complete-frame CPU work and does not include native event handling, presentation, or GPU execution.

## Method

- Repository-pinned Odin `dev-2026-08-nightly:902106f`.
- Optimized telemetry-enabled binaries.
- 300 warm-up frames and 2,000 measured frames.
- Seven randomized adjacent fresh-process baseline/candidate pairs per workload.
- Baseline SHA-256: `c1b6cb3564b72990ac0a00a0e53ace66cffb02497bfb67fca77fff1aef7fd341`.
- Matching valid status, state checksum, output counts, and zero-drop behavior in every pair.

## Adjacent baseline versus candidate

| Workload | Scale | Baseline median | Candidate median | Paired median ratio | Improved pairs |
|---|---:|---:|---:|---:|---:|
| `checkbox_only` | 250 | 15.50 µs | 12.96 µs | 0.8360× | 7/7 |
| `slider_only` | 250 | 16.96 µs | 14.79 µs | 0.8720× | 7/7 |
| `button_only` | 250 | 19.00 µs | 14.46 µs | 0.7598× | 7/7 |
| `input_inactive` | 250 | 18.67 µs | 16.67 µs | 0.8929× | 7/7 |
| `labels_repeated` | 1,000 | 18.92 µs | 13.75 µs | 0.7269× | 7/7 |
| `labels_unique` | 1,000 | 19.42 µs | 14.50 µs | 0.7468× | 7/7 |
| `complex_dashboard` | 250 | 100.12 µs | 86.62 µs | 0.8670× | 7/7 |

The acceptance boundary passed: every target improved in 7/7 pairs, no representative workload regressed, and output invariants matched.

## Candidate direct UI versus Dear ImGui

| Workload | Scale | Direct UI median | ImGui median | UI/ImGui | Paired 95% CI |
|---|---:|---:|---:|---:|---:|
| `complex_dashboard` | 250 | 87.17 µs | 91.38 µs | 0.9544× | 0.9517–0.9577 |

Only complete-frame ratios are cross-framework evidence. Internal phase measurements are descriptive and not primitive-equivalent.

## Code generation

Pinned optimized ARM64 output inlines reservation and direct destination initialization into the measured rectangle and text paths. On successful no-sink paths, fields and zeroed ranges are written directly to the retained 120-byte slot, followed by the count and telemetry increments. The previous full-command stack handoff through `frame_paint_push` and generic `paint_push` is absent. Rejection and configured-sink branches retain a compatibility stack command.

## Verification

- Strict UI tests: 538 passed.
- Telemetry-enabled strict UI tests: 538 passed.
- Widget adapter strict check passed.
- Odin style gate passed.
- Whitespace gate passed.

## Artifacts

Raw records, summaries, paired UI/ImGui output, and extracted assembly are under `benchmarks/widgets/results/artifacts/2026-08-15-ui-paint-append/`.

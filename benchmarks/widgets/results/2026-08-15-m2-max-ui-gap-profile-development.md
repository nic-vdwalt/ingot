# Direct UI Remaining-Gap Profile — Development Evidence

This is local development evidence, not a universal framework ranking. It
profiles the optimized direct `ingot:ui` path after the performance-restoration
pass and keeps complete-frame benchmark evidence authoritative.

## Environment

- Host: Apple M2 Max, arm64.
- OS: macOS 15.6.1 (24G90).
- Workspace revision: `97c108fb7e90f9d8821dd2eae26a14dc40978d0e` plus the uncommitted optimized UI changes.
- Repository Odin pin and profiler build: `dev-2026-08-nightly:902106f`.
- Initial PATH Odin, not used for this collection: `dev-2026-08:8412dc37a`.
- Build flags: `-collection:ingot=. -o:speed -define:INGOT_UI_TELEMETRY=true`.
- Profiler: macOS `/usr/bin/sample`, three 10-second captures at 1 ms intervals.

## Existing complete-frame boundary

| Workload | Scale | Direct UI | ImGui | UI/ImGui | Paired 95% CI |
|---|---:|---:|---:|---:|---:|
| `complex_dashboard` | 250 | 220.27 µs | 206.46 µs | 1.0656× | 1.0476–1.1330 |

This prior result establishes a remaining gap but does not attribute it. The
pinned-toolchain scaling collection below is a separate profiling run and must
not be substituted into that paired cross-framework ratio.

## Sampling Method

The pinned optimized direct-UI binary ran `complex_dashboard:250` for 2,000,000
frames. Three independent 10-second samples captured 8,711, 8,691, and 8,641
main-thread samples. No source-level profiling clocks or production fast paths
were added. Percentages below are top-level sample entries from the profiler;
they overlap when one entry calls another and therefore are not additive.

## Hot-Symbol Attribution

| Rank | Symbol/path | Capture shares | Interpretation |
|---:|---|---:|---|
| 1 | `paint_push` | 16.05%, 15.83%, 16.17% | Largest stable top-level symbol in every capture. |
| 2 | `draw_text_command` | 7.73%, 7.31%, 7.18% | Text command construction and copying are consistently hot. |
| 3 | `frame_paint_push` | 7.09%, 6.66%, 6.21% | Pane application plus another by-value command handoff remain visible. |
| 4 | `measure_text_string_frame` | 3.70%, 3.52%, 3.98% | Material but much smaller than paint command handling. |
| 5 | `interact` | 2.49%, 2.29%, 2.11% | Repeated idle input work is measurable but not the leading contributor. |
| 6 | `checkbox_at` | 2.24%, 2.29%, 2.35% | Stable widget-specific cost below shared paint handling. |
| 7 | inactive-input candidate test | 1.42%, 1.40%, 0.86% | Measurable but less stable and smaller. |

Button and slider work is distributed across several offsets and callees rather
than one top-level entry. Their isolated slopes provide stronger comparison for
those widgets than any single sample line.

## Isolated Workload Scaling

Each cell is the median of seven fresh-process complete-frame medians with 300
warm-up and 2,000 measured frames. All 105 records validated with matching
within-case checksums, submitted/visible widgets, paint/text output, valid
status, and zero dropped commands or text.

| Workload | 50 median | 100 median | 250 median | Per-control slope | Shape |
|---|---:|---:|---:|---:|---|
| `checkbox_only` | 3.375 µs | 6.292 µs | 15.083 µs | 58.54 ns | Linear; segment slopes 58.34/58.61 ns. |
| `slider_only` | 3.584 µs | 6.833 µs | 16.375 µs | 63.95 ns | Linear; segment slopes 64.98/63.61 ns. |
| `button_only` | 4.125 µs | 7.834 µs | 18.750 µs | 73.12 ns | Linear; segment slopes 74.18/72.77 ns. |
| `input_inactive` | 4.000 µs | 7.333 µs | 18.209 µs | 71.05 ns | Near-linear; segment slopes 66.66/72.51 ns. |
| `complex_dashboard` | 19.708 µs | 39.208 µs | 97.375 µs | 388.33 ns/group | Linear; segment slopes 390.00/387.78 ns. |

At scale 250, the dashboard emits 5,000 commands and 2,250 text appends. The
isolated workloads emit 750/250 for checkboxes, 1,000/0 for sliders, 501/250 for
buttons, and 1,250/250 for inactive inputs. The close linearity argues against a
new nonlinear cache or routing failure in this range.

## Paint Command Code Generation

`size_of(Paint_Command)` is 120 bytes under the pinned toolchain. The optimized
ARM64 output preserves material source-level handoffs:

- `frame_paint_push` reserves 176 bytes of stack and copies the full command into
  stack storage before `paint_command_apply_pane`, then calls `paint_push` with
  that stack address.
- `paint_push` reserves 288 bytes of stack, copies the 120-byte command into a
  second local representation, stamps tier/z bytes, and writes the command to
  the destination array with vector loads/stores.
- The successful no-sink path still performs those copies. The sink path adds
  another by-value representation for the callback contract.
- `paint_push_unreserved` is folded into `paint_push` in the optimized binary,
  so eliminating the procedure alone would not address the observed stores.

This agrees with the stable 15.8–16.2% `paint_push` samples and the additional
6.2–7.1% `frame_paint_push` samples. A specialized in-place append design is now
the strongest measured next experiment, but it must preserve pane transforms,
tier/z metadata, clipping reservations, sink delivery, drops, and ordering.

## Text Measurement Cache Evidence

At scale 250, checkbox and button runs each report one initial miss followed by
575,249 accumulated hits; the dashboard reports two misses and 1,150,498 hits.
Slider and inactive-input runs perform no measured backend-cache requests in
this harness. The sampling share for `measure_text_string_frame` is 3.5–4.0%,
while no distinct L0 lookup or map fallback appears among the leading symbols.
The counters are runtime-lifetime totals, not per-frame values. Current evidence
does not justify replacing the bounded eight-entry L0 before paint work.

## Ranked Next Optimization

1. **Specialize common paint appends and initialize destination commands in
   place.** This is supported by the largest stable sampled symbol and confirmed
   120-byte stack/destination copies in pinned optimized code generation.
2. **Reduce text-command construction/copying through the same append design.**
   `draw_text_command` is the second stable sampled symbol and feeds the paint
   path; text ownership and overflow behavior must remain unchanged.
3. **Revisit repeated idle interaction facts only after paint A/B evidence.**
   `interact` is stable at 2.1–2.5%, so it is a plausible later target but cannot
   explain as much of the current frame as paint command handling.
4. **Keep L0 reorganization and runtime geometry-token caching deferred.** Text
   measurement is smaller, cache misses are negligible after warm-up, and token
   procedures do not lead the current profiles.

The next implementation should target paint command construction only. It must
be accepted or rejected using adjacent baseline/candidate complete-frame pairs;
this profile is attribution evidence, not proof that a proposed rewrite wins.

## Raw Evidence

- `benchmarks/widgets/results/artifacts/2026-08-15-ui-gap-profile/dashboard-sample-1.txt`
- `benchmarks/widgets/results/artifacts/2026-08-15-ui-gap-profile/dashboard-sample-2.txt`
- `benchmarks/widgets/results/artifacts/2026-08-15-ui-gap-profile/dashboard-sample-3.txt`
- `benchmarks/widgets/results/artifacts/2026-08-15-ui-gap-profile/scaling.jsonl`
- `benchmarks/widgets/results/artifacts/2026-08-15-ui-gap-profile/frame-paint-push.asm`
- `benchmarks/widgets/results/artifacts/2026-08-15-ui-gap-profile/paint-push.asm`
- `benchmarks/widgets/results/artifacts/2026-08-15-ui-gap-profile/draw-text-command.asm`

## Limitations

- Sampling attribution is statistical and not primitive-equivalent to ImGui.
- Top-level sample percentages overlap and must not be summed.
- Internal groups do not form a cross-framework comparison.
- Telemetry cache counters accumulate for the runtime lifetime.
- Absolute timings are host-, toolchain-, and thermal-state-specific.
- The baseline is the exact uncommitted optimized working tree, not a commit.

# UI Build Performance Improvement Plan

## Scope

This plan targets Ingot's headless core UI build time for the deterministic
`complex_dashboard` benchmark. At 100 rows, the workload submits 1,000 elements:
a unique title, status, checkbox, slider, persistent text input, action button,
and four data cells per row.

The current optimized baseline is approximately 60.8 microseconds of build time
and 0.04 microseconds of finalization per frame on the profiled Apple M2 Max.
Ingot is approximately 5-6% faster than Dear ImGui and 16.5 times faster than
egui for this workload. These results do not represent application, event-loop,
accessibility-host, presentation, or GPU execution performance.

## Profile

A matching 10-second native sample attributed the build cost approximately as
follows. Sampling and nested calls overlap, so these figures identify priorities
rather than providing additive accounting.

| Area | Approximate share | Approximate time per frame |
|---|---:|---:|
| Text emission, copying, and labels | 37% | 22.5 us |
| Text inputs | 21% | 12.8 us |
| Temporary allocation and buffer copying | 15% | 9.1 us |
| Checkbox, slider, and button drawing | 13% | 7.9 us |
| Semantics generation | 3% | 1.8 us |
| Unique-title formatting | 3% | 1.8 us |
| Interaction and other overhead | 8% | 4.9 us |

The first completed optimization replaced a full fixed-capacity accessibility
snapshot copy with a copy of only populated nodes. This reduced finalization
from approximately 3.75 microseconds to 0.04 microseconds without changing the
snapshot contract.

## Objectives

1. Reduce median dashboard build time from approximately 60.8 microseconds to
   40-48 microseconds without removing functionality.
2. Preserve deterministic output, bounded storage, diagnostics, semantics when
   enabled, and existing interaction behavior.
3. Avoid benchmark-only shortcuts. Every optimization must improve production
   UI paths or remove work that production does not require.
4. Keep p95 and memory behavior stable while reducing the median.

## Workstream 1: Text command emission

Text is the largest measured cost and appears six times per dashboard row.
Current label construction clones strings into temporary C strings before
recording text commands, adding allocator traffic and byte copies.

Planned work:

1. Add a length-aware paint-text entry point that accepts an Odin `string`.
2. Copy text directly into the bounded paint-text arena once.
3. Retain C-string entry points as compatibility wrappers rather than forcing
   all callers through temporary C-string conversion.
4. Add a frame-level reserve operation for expected command and text capacity
   where the caller can provide a proven upper bound.
5. Characterize truncation, embedded NUL handling, UTF-8, clipping, and command
   ordering before changing storage paths.

Expected saving: 5-10 microseconds per dashboard frame.

Acceptance criteria:

- Label and text snapshots remain byte-for-byte equivalent.
- No new unbounded allocation or retained per-frame memory is introduced.
- Existing dropped-command and dropped-text diagnostics remain accurate.
- Label-heavy benchmarks improve without regressing unique-text workloads.

## Workstream 2: Inactive text-input fast path

The benchmark's 100 persistent text inputs are unfocused and unchanged. They
still traverse machinery intended for active editing, including selection,
undo, spellcheck, wrapping, caret, and memo handling.

Planned work:

1. Separate immutable display preparation from active editing behavior.
2. Add an inactive, single-line path when the field is unfocused, unchanged,
   unselected, unmasked, and has no active pills or spell menu.
3. Preserve normal background, placeholder/text, clipping, interaction,
   semantics, and focus acquisition.
4. Re-enter the complete path immediately when focus, input, selection,
   masking, pills, spellchecking, multiline layout, or IME requires it.
5. Keep one authoritative predicate for fast-path eligibility and test every
   condition that must disable it.

Expected saving: 4-8 microseconds per dashboard frame.

Acceptance criteria:

- Active editing, keyboard navigation, selection, undo, IME, pills,
  spellchecking, and multiline tests remain unchanged.
- An inactive input produces equivalent paint and semantic output.
- Focus acquisition on pointer interaction still occurs in the same frame.

## Workstream 3: Allocation and copy reduction

Allocator and memory-copy samples overlap text and input work, but remain a
large cross-cutting cost.

Planned work:

1. Instrument frame scratch allocation count, requested bytes, arena growth,
   command growth, text growth, and copied bytes.
2. Reserve bounded paint storage once when a workload or container knows its
   maximum output.
3. Replace repeated small temporary allocations with stack values, stable
   caller-owned buffers, or direct arena writes.
4. Retain high-water capacity across frames while resetting logical lengths.
5. Add limits and assertions for every reserve and growth operation.

Expected saving: 2-5 microseconds per dashboard frame, overlapping partly with
text-command savings.

Acceptance criteria:

- Warm-frame arena growth reaches zero for a stable workload.
- RSS remains bounded during long repeated runs.
- Capacity and hostile-input tests continue to exercise bounded failure paths.

## Workstream 4: Semantics gating

Finalization now copies only populated semantic nodes, but individual widgets
may still build semantic data when semantics are disabled.

Planned work:

1. Trace every semantic-node construction path used by dashboard widgets.
2. Add an early runtime-enabled check before label conversion, node assembly,
   or semantic text copying.
3. Preserve stable IDs and complete node output when semantics are enabled.
4. Benchmark both disabled and enabled modes to prevent optimizing one by
   regressing the other.

Expected saving: 1-2 microseconds per dashboard frame when accessibility is
disabled.

Acceptance criteria:

- Disabled semantics performs no node or semantic-string writes.
- Enabled semantic snapshots remain equivalent and deterministic.
- Accessibility-specific benchmarks show no material regression.

## Workstream 5: Stable title formatting

The dashboard formats `Widget %08d` for every row on every frame even though the
values are stable.

Planned work:

1. Populate stable title buffers once during harness or persistent-state setup.
2. Return immutable views without per-frame formatting.
3. Keep dynamic-churn workloads dynamic so this does not hide real update cost.
4. Add separate stable-text and changing-text measurements.

Expected saving: approximately 1 microsecond per dashboard frame.

Acceptance criteria:

- Stable labels perform no per-frame numeric formatting.
- Dynamic label benchmarks continue to measure formatting and changing text.
- Label content and checksums remain unchanged.

## Workstream 6: Remaining widgets and interaction

Checkboxes, sliders, and buttons are not the primary bottleneck, but should be
revisited after text, input, allocation, and semantics work changes the profile.

Planned work:

1. Re-profile before modifying widget internals.
2. Separate paint, hit-testing, value formatting, and semantic costs with
   isolated workloads.
3. Share measured text and interaction results only when lifetime and cache
   invalidation are explicit.
4. Avoid special casing the dashboard composition.

Expected saving: 1-3 microseconds only if the new profile still identifies a
shared dominant path.

## Measurement Design

Native sampling provides function attribution without perturbing a 60
microsecond frame. Exact component accounting should use isolated workloads,
not a timestamp around each widget call.

Add or retain these measurements:

1. `complex_dashboard` for integrated performance.
2. Labels-only cases with repeated, stable unique, and changing unique text.
3. Inactive and active text-input cases.
4. Checkbox-only, slider-only, and button-only cases.
5. Semantics-disabled and semantics-enabled pairs.
6. Warm and forced-growth paint-arena cases.

For each comparison:

- Use release-speed builds and fixed framework revisions.
- Run at least five fresh-process repetitions.
- Use at least 100 warm-up and 500 measured frames for development checks.
- Use the full 300 warm-up, 2,000 frame, seven-repetition protocol for accepted
  evidence.
- Report paired total, build, and finalization medians plus p95.
- Retain raw JSONL, aggregate output, environment, compiler, and power state.

## Telemetry Contract

Step 1 is implemented behind `INGOT_UI_TELEMETRY`. `ui_frame_telemetry` exposes
per-frame counters after finalization:

- Scratch allocation and resize request counts.
- Total requested bytes for allocation and resize operations.
- Successful command appends for main and overlay paint lists.
- Successful text-storage appends and bytes actually copied.
- Command and text storage growth counts, currently always zero because paint
  storage uses fixed-capacity arrays.
- Full text-input path calls and inactive fast-path candidates.

The scratch byte fields describe allocator requests, not live bytes, peak bytes,
or backing-arena growth. Odin's core `Dynamic_Arena` does not expose backing
block growth through its current public API, so actual arena growth remains a
known instrumentation limitation. Text copied before an associated command is
rejected remains counted because it was actual work; characterization tests lock
that existing behavior until text recording is redesigned.

## Implementation Order

1. Add allocation, copy, command, text, and input-path counters. Completed.
2. Add isolated workloads and establish reproducible baselines.
3. Implement direct string-to-paint recording and bounded reservation.
4. Implement and characterize the inactive text-input fast path.
5. Gate widget-side semantics construction when disabled.
6. Cache stable benchmark title formatting.
7. Re-profile and decide whether widget or interaction work remains material.
8. Run full correctness, fuzz, formatting, web, benchmark, and soak validation.

Each workstream should land independently with before-and-after evidence. If a
change does not improve representative workloads, or shifts cost into memory,
p95, active input, or accessibility, it should not be retained.

## Validation Matrix

Run after each production change:

```sh
odin test ui -collection:ingot=. -define:ODIN_TEST_THREADS=1
bash scripts/check.sh
python3 benchmarks/widgets/runner/bench.py smoke
```

Run before accepting the completed plan:

```sh
bash scripts/test.sh -define:ODIN_TEST_THREADS=1
bash scripts/check.sh
bash scripts/check-web.sh
python3 benchmarks/widgets/runner/bench.py run \
  --workload complex_dashboard --scale 100 \
  --output /tmp/complex-dashboard-optimized.jsonl
python3 benchmarks/widgets/runner/bench.py validate \
  --output /tmp/complex-dashboard-optimized.jsonl
```

Also run text-input fuzzing, capacity tests, semantics snapshots, inactive and
active input characterization, and a long stable-workload RSS trace.

## Risks

- Fast paths can diverge from complete widget behavior as features evolve.
- String views can outlive source buffers if ownership is not explicit.
- Reservation can hide excessive capacity or bypass bounded-drop diagnostics.
- Caches can return stale text after DPI, font, theme, locale, or value changes.
- Disabled-accessibility optimizations can accidentally weaken enabled output.
- Microbenchmark improvements can fail to transfer to clipped, interactive,
  text-heavy, or renderer-inclusive applications.

These risks require one authoritative path-selection predicate, paired
assertions at ownership boundaries, bounded storage, characterization tests,
and measurements across both optimized and fallback paths.

## Completion Criteria

The plan is complete when:

1. Median dashboard build time is 48 microseconds or lower on the baseline
   machine, with a stretch target of 40 microseconds.
2. Finalization remains below 0.1 microseconds with semantics disabled.
3. p95 does not regress by more than 5% relative to the improved median trend.
4. Stable warm frames perform no avoidable arena growth.
5. Active text editing and enabled accessibility show no material regression.
6. All project tests, checks, web builds, fuzz cases, and benchmark validation
   pass.
7. A dated report records raw results and any workload-specific limitations.

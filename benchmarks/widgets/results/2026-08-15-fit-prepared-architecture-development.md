# Fit Prepared Architecture Development Evidence - 2026-08-15

This development evidence measures the public `ingot:fit` prepared solver after adding bounded topology and traversal telemetry, incremental dependency metadata, and direct geometry for eligible fixed-height grids and fixed nested rows.

## Environment

- Machine: Apple M2 Max, arm64
- OS: macOS 15.6.1
- Compiler: local Odin `dev-2026-08:8412dc37a`; the repository pin is `dev-2026-08-nightly:902106f`
- Build: `-o:speed`, `INGOT_UI_TELEMETRY=true`
- Dashboard comparison: 100 warm-up frames, 500 measured frames, five randomized fresh-process pairs
- Fixed topology characterization: 100 warm-up frames, 500 measured frames, five fresh processes
- Validation: UI and Fit package tests, complete repository tests, benchmark smoke, strict Odin checks, Python syntax, and JSON validation passed

The strict repository gate stopped only at its pinned-toolchain check before running its remaining checks. Equivalent local strict checks passed.

## Complete-Frame Result

The 50-row `complex_dashboard` candidate/baseline complete-frame ratio was **0.7889** with a paired bootstrap 95% interval of **0.7859-0.7892**, a development improvement of about **21.1%**. The cache-bypassed/enabled ratio was 0.9707, so text measurement caching was not credited for the architectural gain.

## Prepared Cost Evidence

For `prepared_flat_fixed` at 2,048 leaves:

- Complete-frame median/p95: 397.54/513.31 microseconds
- Description build median/p95: 225.00/248.01 microseconds
- Measure median/p95: 71.75/117.60 microseconds
- Layout/render median/p95: 98.92/129.04 microseconds
- Description nodes: 2,049
- Maximum depth: 2
- Counted whole-tree visits: 2,049, exactly 1.00 per node
- Specialized nodes: 2,049
- Generic fallback nodes: 0
- Natural, dependency, resolve, remeasure, resolved-measure, and generic placement visits: 0

The fixed path still performs bounded child geometry work and a depth-first render. The visit ratio counts named whole-tree solver passes; child-run visits are reported separately.

## Architecture

Description construction now records leaf/container counts, maximum depth, axis dependencies, and whether explicit sizing exists while links are created. Generic descriptions no longer scan the tree solely to rediscover axis dependencies, and they skip explicit-size resolve/remeasure when no node requests it.

Eligible fixed-height root grids with fixed leaves, including fixed row children, bypass intrinsic callbacks and generic solve passes. Wrapping, custom measures, aspect ratios, transitions, attachments, scrolls, unsupported nested containers, and non-fixed leaves retain the bounded generic solver.

## Limits

These are development measurements, not the full accepted 300/2,000/7 protocol. The direct path is intentionally narrow. Dear ImGui remains contextual because its adapter uses fixed placement, a narrower host boundary, and no core accessibility output. Complete-frame comparisons are authoritative; internal phase clocks and counters are attribution only.

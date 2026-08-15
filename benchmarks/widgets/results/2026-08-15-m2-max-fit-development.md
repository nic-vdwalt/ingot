# Fit Headless Development Results - 2026-08-15

These are local development measurements of the public `ingot:fit` adapter, not a universal
framework ranking. The Ingot timing includes high-level description construction, measurement,
layout, interaction, paint, semantics when enabled, and frame finalization. Dear ImGui and egui use
the suite's fixed-placement core adapters. The different integration layers make this a practical
workload comparison, not a primitive-for-primitive cost comparison.

## Environment

- Machine: Apple M2 Max, arm64
- OS: macOS 15.6.1
- Drawable contract: 1280x720, scale factor 1; refresh metadata was not set
- Power metadata: not set
- Collection: 100 warm-up frames, 500 measured frames, five fresh processes per case
- Ingot: workspace, layer `fit`, local Odin `dev-2026-08:8412dc37a`
- Dear ImGui: `5d4126876bc10396d4c6511853ff10964414c776` (v1.92.1)
- egui: `f2ab57d6987a9b7984f0637cc4d9f2fd173c507c` (0.32.3), Rust 1.90.0
- Validation: 165 records; shared state checksums agreed; nominal dropped output was rejected

The repository pins Odin `dev-2026-08-nightly:902106f`, but the available local compiler was
`dev-2026-08:8412dc37a`. The strict repository gate therefore stopped at its toolchain check. Targeted
Fit tests, strict Odin vet checks, benchmark smoke, JSON validation, and checksum conformance passed.

## Representative Results

Lower is better. The table records the original adapter phases, but its ratios compare Ingot's
complete Fit frame with competitor build-only medians. That convention is inconsistent and must not
be used as a framework-total comparison. Dear ImGui finalize is negligible; egui total comparisons
must include its separately measured tessellation/finalize phase.

| Workload | Scale | Ingot Fit total median/p95 | Dear ImGui build (descriptive only) | egui build (descriptive only) |
|---|---:|---:|---:|---:|
| Repeated labels | 2,000 | 551.81/621.79 us | 92.96 us | 1,333.96 us |
| Unique labels | 2,000 | 553.04/615.72 us | 160.62 us | 1,356.60 us |
| Button grid | 250 | 123.96/139.00 us | 38.42 us | 313.79 us |
| Mixed form | 50 groups | 110.42/123.38 us | 28.54 us | 278.96 us |
| Complex dashboard | 50 rows | 199.42/219.50 us | 45.58 us | 466.08 us |
| Full list | 2,000 rows | 553.88/641.76 us | 160.58 us | 1,350.17 us |
| Virtual list | 1,000,000 logical / 44 built | 10.54/10.88 us | 7.50 us | 36.12 us |
| Repeated table cells | 1,000 cells | 273.62/304.67 us | 42.88 us | 644.73 us |
| Unique table cells | 1,000 cells | 273.71/279.25 us | 73.12 us | 639.42 us |
| Dynamic churn | 2,000 items | 548.79/555.93 us | 114.71 us | 1,519.46 us |
| Accessibility buttons | 250 | 158.33/176.75 us | 38.50 us | 315.88 us |

## Where Fit Stands

- The Dear ImGui and egui columns are build-only historical context. Earlier ratios that divided Fit
  complete frames by those values are withdrawn because their timing boundaries differ.
- A current direct-`ingot:ui` mode now provides the fixed-placement Ingot baseline. Fit/UI overhead
  claims require fresh same-revision paired records; the July 29 direct-UI report remains provenance.
- Fit description construction was not the dominant cost. For the 50-row dashboard, build was
  52.79 us and measure/render/finalization was 145.71 us of the 199.42 us total median.
- Stable repeated and unique labels had nearly identical Fit totals. At this layer, measurement,
  layout, and paint dominated any stable-label identity difference.
- Virtualization remained effective: 44 built rows completed in a 10.54 us total median independent
  of the one-million-row logical size.

## Capacity and Methodology

Fit descriptions use caller-owned storage with an 8,192-node hard maximum. Additional production
bounds are lower for particular structures: grids hold at most 4,096 items and a frame holds at most
256 focusables. Shared workload scales were reduced to respect all applicable Fit bounds; larger
Dear ImGui and egui scales are framework-only characterization cases.

These results supersede no prior direct-`ingot:ui` evidence. The July 29 adapter emitted fixed geometry
directly through core UI calls and measured a materially smaller scope. Comparing its values with this
Fit run would attribute added layout and public-package work to a regression rather than a methodology
change. Native rendering, GPU execution, presentation, memory, startup, idle power, and accessibility
host integration remain outside this run.

Raw development data and generated aggregates were retained locally at
`/tmp/widget-fit-development.jsonl` and `/tmp/widget-fit-report`.

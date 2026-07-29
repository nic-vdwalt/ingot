# Choosing Ingot

Ingot is an Odin app framework for polished desktop tools that also need a web
build. It combines an immediate-mode UI, a raylib-shaped graphics layer, WebGPU
rendering, platform integration, networking, settings, accessibility semantics,
and an optional terminal stack in one source tree.

It is not intended to replace every GUI toolkit or game engine. The useful
question is whether its constraints match the application.

## Where Ingot fits

Choose Ingot when most of these are true:

- The application is written in Odin and should remain mostly or entirely Odin.
- One codebase must target macOS, Windows, Linux, and WASM + WebGPU.
- The product is a desktop tool, editor, dashboard, terminal application, or
  two-dimensional game rather than a content-heavy 3D game.
- Explicit state ownership and deterministic, headless testing matter more than
  a retained visual designer or a large extension ecosystem.
- Custom rendering, native desktop presentation, and efficient idle behavior
  should live in the same framework.
- Pinning a young framework revision and participating in its evolution is
  acceptable.

Choose another stack when any of these are hard requirements:

- A mature visual designer, broad third-party widget catalog, or long-term API
  stability backed by a large ecosystem.
- First-class mobile targets.
- A complete 3D scene graph, asset pipeline, physics stack, or game editor.
- The operating system's native widgets and exact native control behavior.
- A browser-first document application that depends on the DOM, CSS, or the web
  accessibility ecosystem as its primary UI model.

## Comparison at a glance

The categories below overlap, but they represent the most likely alternatives.

- **Ingot:** Best for Odin desktop tools with native and web targets. Its strict
  single-path model keeps persistent widget behavior in caller-owned state and
  derives bounded UI output only for the current frame. The stack integrates
  batched WebGPU rendering and event-driven idle behavior, but is young and
  Odin-specific.
- **Dear ImGui:** Best for mature C++ engine tooling, inspectors, overlays, and
  applications that already own a renderer or platform shell. It has much wider
  adoption, backend coverage, tables, and docking than Ingot, but no core
  accessibility implementation.
- **egui:** Best for Rust-native tools and applications that value native/web
  portability, higher-level layout, scheduled repaint, and AccessKit semantics.
  With `eframe` it approaches Ingot's app-framework scope, while retaining a much
  larger ecosystem and a less strictly caller-owned state model.
- **Qt, GTK, or Slint-style toolkit:** Best for conventional applications and
  mature widget needs. Ingot offers direct ownership and custom rendering;
  established toolkits offer deeper widgets, tooling, and stability.
- **Flutter or Compose-style UI:** Best for product UI spanning several
  platforms. Ingot is smaller and Odin-native; these stacks have richer
  ecosystems and mobile support.
- **Electron or Tauri-style app:** Best for web-oriented teams and DOM-based
  product interfaces. Ingot avoids a webview and JavaScript frontend; web stacks
  offer unmatched browser libraries and hiring familiarity.
- **raylib:** Best for small games, visualization, and hand-built tools. Ingot
  keeps a familiar API shape and adds widgets, accessibility, idle scheduling,
  networking, settings, and desktop integration.
- **Full game engine:** Best for content-heavy games with editors and asset
  workflows. Ingot is a compact app framework with a 3D escape hatch, not a
  scene-graph or content-production engine.
- **Platform-native UI:** Best when exact OS controls and conventions are
  required. Ingot shares rendering and UI across targets; native stacks provide
  the deepest platform fidelity.

These points compare architectural defaults, not absolute capability. Any of
these stacks can be extended, and individual libraries within a category differ.
Evaluate the current release of a candidate before making a product decision.

## Against immediate-mode UI libraries

Ingot shares the application-facing IMGUI lineage of Dear ImGui, Nuklear, Gio,
and egui. Immediate mode historically describes how application code expresses
the interface; it does not require stateless library internals, immediate GPU
rendering, or a continuously running frame loop. These are genuine
immediate-mode systems even when they retain caches, schedule redraws, or emit
accessibility data.

### Why Ingot is the purest form of immediate mode

Ingot can reasonably call itself the purest form of immediate-mode GUI in one
specific architectural sense: the application remains the single source of
truth for persistent widget behavior. State flows directly from application or
component data into each frame's interface declaration, without a retained
widget tree or hidden UI state store that must be kept in sync.

Concretely, this means:

- There is no retained widget tree.
- There is no hidden ID-keyed database for persistent widget behavior.
- Stable IDs identify current-frame controls for focus and accessibility; they
  do not own control state.
- Application or component structs explicitly own editing, scrolling, menu,
  selection, and interaction state.
- Each required frame derives input routing, focus, accessibility semantics,
  platform output, and paint together from the current interface declaration.
- Persistent caches, GPU resources, text systems, semantic snapshots, and
  platform adapters live behind explicit runtime services. They accelerate or
  connect the interface without becoming a second application model.

This is immediate mode at the application boundary, not statelessness inside the
implementation. A frame may be deferred, batched, compared with an earlier
snapshot, or skipped entirely while the application is idle; none of those
choices transfer authority over persistent widget behavior away from the
caller.

One practical consequence is verification cost. Because the frame boundary is
already explicit state in and bounded data out, deterministic harnesses drive
production widgets directly and check routing, focus, layout, and accessibility
as values, without a window, a GPU, or a test-only model of the widget tree. A
toolkit whose source of truth is a retained tree must first expose or rebuild
that tree before it can be simulated. This is a consequence of the ownership
model rather than a quality claim about other toolkits, but it is a real
difference in what testing costs. [Testing Ingot](testing.md) sets out the
argument and the harnesses.

Here, "purest" refers only to this single-source-of-truth ownership model: the
application owns persistent widget behavior, while Ingot derives each required
frame from the state it receives. It is not a claim about maturity or feature
breadth, nor does it require stateless internals, immediate GPU submission, or
continuous redraw. Dear ImGui, egui, Gio, and Nuklear remain genuine IMGUI
systems with different ownership and integration tradeoffs.

Dear ImGui and egui should not be treated as one interchangeable category. Dear
ImGui is primarily a C++ UI library designed to embed into engines and custom
applications. egui is a Rust UI library whose official `eframe` framework and
renderer/platform crates also provide a native and web application stack. Ingot
is an Odin framework that integrates UI with its own graphics and application
services. Compare the complete stack required by the application, not only the
widget-call syntax.

### Ingot, Dear ImGui, and egui

This table describes architectural defaults rather than every extension. Dear
ImGui docking is maintained on its official docking branch; egui docking is
normally supplied by third-party crates.

| Area | Ingot | Dear ImGui | egui |
|---|---|---|---|
| Primary ecosystem | Odin desktop tools, native and browser builds | C++ engines, tools, overlays, and custom applications | Rust native and web tools and applications |
| Integration boundary | App framework with UI, WebGPU graphics, frame pacing, platform effects, settings, networking, and terminal packages | Renderer-agnostic UI core with official renderer and platform backends; normally embedded in a host | Renderer-agnostic UI core with official `winit`, `wgpu`, `glow`, and `eframe` integrations |
| Persistent UI behavior | Component state such as editing, scrolling, menus, and interaction latches is caller-owned | Application values are caller-owned; the context retains window, table, navigation, and interaction state keyed by widget identity | Application values are caller-owned; `Context` and `Memory` retain focus, window, scroll, collapse, and text-edit state keyed by IDs |
| Identity | Stable IDs identify current-frame focus and accessibility targets, not a general widget-state store | Labels and an ID stack produce stable widget IDs | Sequential widgets often receive IDs automatically; persistent state requires stable IDs |
| Layout | Bounded single-pass rows, columns, flex sizing, fit-content columns, and explicit-size flow; measurement and geometry escape hatches remain application-owned | Cursor-driven layout, explicit composition, child regions, and mature tables | Closure-based rows, columns, panels, grids, wrapping, scroll areas, and occasional extra layout passes |
| Rendering output | Bounded renderer-independent paint lists replayed by the integrated WebGPU adapter | Batched indexed triangle draw lists consumed by a renderer backend | Shapes, texture updates, and platform output tessellated and painted by an integration |
| Performance model | Bounded frame storage, reusable scratch memory, batched drawing, renderer statistics, and optional event-driven frames | Allocation-conscious core and mature batching; host renderer, backend, and frame loop determine end-to-end cost | Retained caches, tessellation, repaint scheduling, and integration choices determine end-to-end cost |
| Idle scheduling | `Frame_Pacer` can skip UI construction and GPU submission until input, application work, or a redraw deadline | Commonly rebuilt in a continuous engine loop; event-driven hosting is possible but not the primary integration model | Repaint requests and deadlines allow integrations to sleep while idle |
| Accessibility | Widgets emit bounded semantic snapshots; native AccessKit and browser semantic-DOM bridges exist, but target validation is not recorded | No accessibility implementation in the core project | Built-in AccessKit semantics exposed through integrations, including `eframe` |
| Docking and detached tools | Docking is roadmap work; explicit native contexts can own independent windows, with platform validation still required | First-party docking and multi-viewports on the official docking branch | Core multi-viewport protocol; docking normally comes from ecosystem crates |
| Predictability tradeoff | Named capacities bound frame work and storage; exceeding a contract degrades or asserts according to the API | Highly optimized and allocation-conscious, with dynamic internal structures | Safe Rust implementation with dynamic containers and optional persistence/serialization features |
| Maturity | Young, Apache-2.0 licensed, no semantic-versioned releases, and a small Odin ecosystem | More than a decade of broad production use and backend integrations | Production-capable and widely used, but younger than Dear ImGui and still permits breaking releases |

### What the table means

Ingot's clearest distinction is state ownership. Persistent widget behavior
belongs to application component structs; stable IDs identify focus and
accessibility targets but do not key a hidden widget-state database.
`Ui_Runtime` owns explicit window-lifetime services, while `Ui_Frame` owns
bounded output and arbitration for one rendered frame. Caches and platform
backing structures may persist without becoming a second application model.
This makes teardown and headless tests explicit, at the cost of more state in
application types than callers of Dear ImGui or egui may expect.

Ingot's intended boundary is also broader than Dear ImGui's core. It includes
windowing, graphics, application frame pacing, platform effects, settings,
networking, accessibility semantics, and terminal support rather than assuming
an existing host engine or application shell. The fairer egui comparison is
often Ingot against `egui` plus `eframe` and its renderer/platform crates. Gio
and egui already demonstrate event-driven immediate-mode frames and semantics,
so Ingot does not claim those ideas as unprecedented.

Ingot's bounds provide explicit workload and storage ceilings, not automatic
superiority. They can simplify failure analysis and deterministic testing, but
large or highly dynamic interfaces must fit the capacities and widget set that
exist today. Dear ImGui has substantially deeper tables, docking, backend
coverage, and operational history. egui has richer general layout, an
established Rust crate ecosystem, and more mature accessibility integration.
Neither comparison should imply current feature parity.

For performance, Ingot is designed to reuse bounded frame storage, batch paint,
and avoid both UI construction and GPU submission while idle. Dear ImGui is
also highly optimized and allocation-conscious, while egui can cache work and
schedule repaint deadlines.

An accepted [Apple M2 Max Phase 2 baseline](../benchmarks/widgets/results/2026-07-26-m2-max-phase-2.md)
of the [scalable widget suite](../benchmarks/widgets/README.md) measured Ingot's
deterministic 100-row dashboard at a 46.21 µs total median and 53.46 µs total
p95. The workload submits 1,000 fixed-geometry UI elements; its build median was
45.88 µs and finalization p95 was 0.04 µs across seven fresh processes, each with
300 warm-up and 2,000 measured frames. Isolated cases separately measure stable
and changing labels, active and inactive inputs, widgets, and semantics.

The [2026-07-29 cross-framework run](../benchmarks/widgets/results/2026-07-29-m2-max-core.md)
remains evidence for specific pinned Dear ImGui and egui adapters and workloads.
Neither result establishes an overall framework ranking or proves equivalent
feature work. These headless-core CPU adapters do not measure native host
integration, GPU execution, presentation, memory, startup, or idle power.
End-to-end results still depend on the host, backend, workload, and build
configuration. Ingot's renderer statistics can expose flushes, uploads, CPU
encoding/submission calls, state switches, and arena peaks during a future
native measurement.

Platform claims also require qualification. The shared Ingot API targets macOS,
Windows, Linux, and the browser, but compilation is not runtime validation.
Native accessibility, assistive technology, WebGPU backends, browser behavior,
and multi-window presentation still require dated evidence on representative
systems. See [Production readiness](production-readiness.md) for the current
matrix and [Testing Ingot](testing.md) for what package, web, fuzz, and GPU tests
actually establish.

Prefer Dear ImGui when integrating into an existing C++ renderer or engine, or
when mature docking, tables, backend breadth, and operational history dominate.
Prefer egui when Rust, higher-level layout, its crate ecosystem, or established
AccessKit integration dominate. Prefer Ingot when one Odin-owned stack, explicit
component state, bounded frame derivation, and shared native/WebGPU architecture
matter more than ecosystem size and current widget depth.

The external claims above were reviewed against the upstream projects in July
2026. Recheck them when selecting a dependency because branches, integrations,
and release policies change:

- Dear ImGui [repository](https://github.com/ocornut/imgui),
  [backends](https://github.com/ocornut/imgui/blob/master/docs/BACKENDS.md), and
  [docking notes](https://github.com/ocornut/imgui/wiki/Docking)
- egui [repository and architecture](https://github.com/emilk/egui),
  [`Context` repaint API](https://docs.rs/egui/latest/egui/struct.Context.html),
  and [viewport API](https://docs.rs/egui/latest/egui/viewport/index.html)
- Ingot [state model](ui-state.md), [rendering boundary](rendering.md),
  [test coverage](testing.md), and
  [platform-validation matrix](production-readiness.md)

## Against retained and declarative UI toolkits

Qt, GTK, Slint, Flutter, and Compose-style systems are better defaults when the
application benefits from mature controls, designers, localization workflows,
mobile support, or established platform integrations. Their retained or
reactive models can also be productive when a team already understands the
framework's lifecycle and state conventions.

Ingot instead keeps the application's own data as the persistent source of truth
and derives interaction, focus, overlays, semantics, and drawing whenever a
frame is required. That makes ownership and teardown visible and lets tests drive
production widgets with synthetic input without reconstructing a private object
hierarchy. It does not forbid internal retention: layout caches, text systems,
GPU resources, and semantic snapshots can persist behind explicit owners.

The cost is that applications may need to build specialized controls and product
infrastructure that established toolkits already provide. Accessibility support
also needs validation on each target; semantic output is part of Ingot's design,
but ecosystem maturity is not equivalent to mature native toolkits.

For performance, Ingot avoids maintaining and diffing a retained widget tree,
uses bounded per-frame outputs, batches drawing, and can do no frame work while
idle. Retained and declarative toolkits can instead reuse layout, rendering, and
widget caches when only part of an interface changes, and mature toolkits may
have heavily optimized native paths. The winning model depends on invalidation
patterns, control count, text complexity, animation, and backend quality. Compare
frame-time distributions, memory, startup, and idle CPU on the actual product;
architecture alone does not establish that Ingot is faster.

## Against Electron and Tauri-style applications

Electron and Tauri are compelling when the product is naturally a web
application, the team relies on browser libraries, or HTML and CSS are central
to its design system. Tauri can reduce the host footprint, but both approaches
normally retain a web frontend and its programming model.

Ingot uses Odin for application and UI code and renders through WebGPU without a
desktop webview. This gives native and browser builds one explicit rendering and
state model, avoids synchronizing a native backend with a JavaScript frontend,
and permits event-driven frames with no GPU submission while idle.

That architecture can reduce runtime layers, baseline memory, startup work, and
idle activity relative to shipping a browser frontend, especially compared with
Electron. It is not a universal performance advantage: browser engines have
mature layout, text, accessibility, compositing, and profiling implementations;
Tauri uses the operating system webview rather than bundling Chromium; and a
custom WebGPU UI may perform more application-side work. Measure packaged
binary size, cold and warm startup, resident memory, idle CPU and power, and
interactive frame times on every target instead of relying on framework labels.

Prefer a web stack when DOM semantics, browser layout, web content embedding,
frontend staffing, or the npm ecosystem outweigh the benefits of a single Odin
codebase and custom renderer.

## Against raylib and full game engines

Ingot's graphics API deliberately resembles raylib, making many drawing, input,
math, texture, camera, and `rlgl` call sites familiar. On top of that foundation,
Ingot supplies an application-oriented UI and services needed by desktop tools.
It is a stronger fit than bare raylib when those services would otherwise become
a private framework maintained inside the application.

A full game engine remains the better choice for scene editing, imported asset
pipelines, animation graphs, physics, navigation, scripting, or large 3D worlds.
Ingot supports two-dimensional games and an optional GPU 3D path for
visualization, but does not aim to become a scene-graph engine or game editor.

For performance, Ingot adds UI derivation, semantic output, platform services,
and frame-pacing machinery beyond bare raylib, so applications should not assume
those features are free. In return, it batches renderer-independent paint,
reuses bounded storage, exposes renderer statistics, and can sleep without UI or
GPU work. A full engine carries broader subsystems but may offer more advanced
culling, streaming, profiling, and platform-specific optimization for complex
scenes. Benchmark the required feature set rather than a minimal draw loop, and
compare CPU and GPU frame time, memory, startup, idle behavior, and asset-loading
costs on representative content.

## Decision checklist

Before adopting Ingot, build a small vertical slice and verify:

1. The required controls and text-input behavior exist or are practical to add.
2. Accessibility semantics and keyboard operation meet the product's target on
   every supported operating system.
3. The WebGPU backend and distribution model work on the required hardware.
4. The native and browser builds satisfy binary-size, startup, idle CPU, and
   frame-time goals with measured results.
5. Pinning Ingot and the tested Odin toolchain fits the release process.
6. Missing roadmap items such as docking, virtualized data views, complex text
   input, or Linux polish do not block the first release.

If that slice succeeds, Ingot offers a compact architecture: application-owned
state, bounded per-frame derivation, one renderer across native and web, and an
app stack that remains inspectable from Odin. If it fails on a hard requirement,
choose the alternative whose native model already supplies that requirement
rather than forcing Ingot beyond its intended boundary.

For the architectural rationale, read [Why immediate mode](immediate-mode.md).
For concrete ownership rules, read [UI state and stable focus](ui-state.md).
For current verification coverage and limits, read [Testing Ingot](testing.md).

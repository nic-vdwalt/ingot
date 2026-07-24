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

- **Ingot:** Best for Odin desktop tools with native and web targets. It combines
  caller-owned state, immediate UI, batched WebGPU rendering, and event-driven
  idle behavior. The stack is integrated and inspectable, but young and
  Odin-specific.
- **Dear ImGui or egui-style UI:** Best for debug tools, inspectors, engine
  tooling, and custom-rendered utilities. Ingot provides a broader app stack and
  explicit runtime/frame boundary, but has a smaller ecosystem.
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

Ingot shares the direct, frame-by-frame declaration model associated with Dear
ImGui and egui-style libraries, but its intended boundary is broader. It includes
windowing, graphics, application frame pacing, platform effects, settings,
networking, accessibility semantics, and terminal support rather than assuming
an existing host engine or application shell.

Its stricter distinction is state ownership. Persistent widget behavior belongs
to application component structs; stable IDs identify focus and accessibility
targets but do not key a hidden widget-state database. `Ui_Runtime` owns explicit
window-lifetime services, while `Ui_Frame` owns bounded output and arbitration
for one rendered frame.

Prefer a standalone immediate-mode UI library when integrating into an existing
renderer or engine, when its ecosystem already supplies required widgets, or
when framework-level services would be redundant.

## Against retained and declarative UI toolkits

Qt, GTK, Slint, Flutter, and Compose-style systems are better defaults when the
application benefits from mature controls, designers, localization workflows,
mobile support, or established platform integrations. Their retained or
reactive models can also be productive when a team already understands the
framework's lifecycle and state conventions.

Ingot instead keeps the application's own data as the persistent source of truth
and derives interaction, focus, overlays, semantics, and drawing each frame.
That makes ownership and teardown visible and lets tests drive production widgets
with synthetic input without reconstructing a private object hierarchy.

The cost is that applications may need to build specialized controls and product
infrastructure that established toolkits already provide. Accessibility support
also needs validation on each target; semantic output is part of Ingot's design,
but ecosystem maturity is not equivalent to mature native toolkits.

## Against Electron and Tauri-style applications

Electron and Tauri are compelling when the product is naturally a web
application, the team relies on browser libraries, or HTML and CSS are central
to its design system. Tauri can reduce the host footprint, but both approaches
normally retain a web frontend and its programming model.

Ingot uses Odin for application and UI code and renders through WebGPU without a
desktop webview. This gives native and browser builds one explicit rendering and
state model, avoids synchronizing a native backend with a JavaScript frontend,
and permits event-driven frames with no GPU submission while idle.

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

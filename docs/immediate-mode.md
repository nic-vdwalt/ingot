# Why immediate mode

Ingot starts from a simple position: a retained widget tree is not required to
build a complete desktop interface.

Retained-mode libraries usually combine several separate concerns behind one
object graph: application state, widget identity, layout, event routing,
rendering, accessibility, and resource lifetime. That can be convenient, but it
also creates a second model of the application that must be synchronized with
the first. State can outlive the screen that created it, identity can depend on
labels or call sites, and framework behavior can become difficult to inspect or
test.

Ingot keeps those concerns separate. The application owns persistent behavior
and presents the current interface when a frame is required. The framework
derives bounded frame output from that declaration: draw commands, interactions,
overlays, focus registration, and accessibility semantics. There is no
framework-owned widget tree and no label-hashed state store.

This is not a claim that useful interfaces have no state. It is a claim that the
state should have an obvious owner.

## The idea before Ingot

Immediate-mode GUI began as an application-interface idea, not a rendering rule.
Casey Muratori developed the approach in 2002 while building a Granny 3D viewer,
called it a "single-path immediate-mode graphical user interface," and presented
it publicly in 2005. The "single path" matters: application code should not have
to create a parallel hierarchy of widget objects and then keep that hierarchy
synchronized with the data it represents.

Muratori explicitly allowed the library to retain internal structures between
frames. The immediate boundary was the interface presented to application code,
not a requirement that the implementation remember nothing. Omar Cornut later
made the same distinction in Dear ImGui's documentation: IMGUI describes the API
between the application and UI system, favors application data as the source of
truth, and minimizes duplicated state and synchronization from the caller's
point of view.

There is no universally agreed formal definition of IMGUI. Ingot follows that
original application-facing interpretation:

```text
application state -> declare current interface -> derived UI output
```

rather than requiring the application to maintain this relationship:

```text
application state <-> synchronize <-> persistent widget object graph
```

This history also sets an important limit on Ingot's claims. Dear ImGui,
Nuklear, Gio, egui, and other systems are genuine immediate-mode libraries even
when they retain caches or interaction data internally. Ingot does not define
them out of the paradigm. Its position is that the same boundary can support a
complete application GUI rather than only an engine overlay or debugging tool.

Primary historical context:

- Casey Muratori, [Immediate-Mode Graphical User Interfaces](https://caseymuratori.com/blog_0001)
- Dear ImGui, [About the IMGUI paradigm](https://github.com/ocornut/imgui/wiki/About-the-IMGUI-paradigm)
- Dear ImGui, [FAQ: traditional toolkits and IMGUI](https://github.com/ocornut/imgui/blob/master/docs/FAQ.md#q-what-is-the-difference-between-dear-imgui-and-traditional-ui-toolkits)

## Immediate interface, deferred rendering

Immediate-mode GUI and immediate-mode graphics are separate ideas. An Ingot
widget call appends interactions, semantics, and paint data to a frame. The
renderer later batches and submits that paint through WebGPU. GPU resources,
font atlases, text caches, and platform adapters necessarily persist.

"Each frame" also means each interface evaluation that actually occurs, not a
mandatory polling loop. An event-driven Ingot application can sleep with no UI
construction and no GPU submission, wake for input, network data, or a redraw
deadline, derive one frame, and sleep again. Gio and egui demonstrate related
modern immediate-mode patterns through explicit invalidation and scheduled
repaint APIs. Continuous redraw is useful for games, but it is not part of the
IMGUI definition.

## The state model

Ingot divides UI data into three categories:

1. **Application and component state.** Text, selections, open menus, scroll
   positions, slider values, and interaction latches live beside the feature
   that uses them. Their lifetime and teardown are explicit.
2. **Runtime services.** A window-owned `Ui_Runtime` holds resources such as
   text and spell systems, theme data, metrics, and DPI tracking. These are
   explicit services, not a widget model.
3. **Frame output.** A `Ui_Frame` holds transient routing, overlays,
   interactions, semantics, and accessibility actions. It is rebuilt for the
   rendered frame and then discarded or reused.

Stable IDs identify focus and accessibility targets. They do not become keys
into a hidden state database. Semantic snapshots are pointer-free, live action
links last only for the open frame, and Tab traversal resolves the current
frame's registration order at frame end. Accessibility activation is bounded to
the immediately following frame, so a removed control cannot retain an action.

See [UI state and stable focus](ui-state.md) for ownership rules and concrete
Odin examples. [Choosing Ingot](comparison.md) compares this model with other
app engines and UI stacks.

## Frame scratch lifetime

Allocate transient UI data with `ui_frame_allocator(frame)`. The allocation is
valid only until the frame is released by `ui_frame_end`; never individually
free or delete it. Guarded builds panic at the offending call site with
`individual free of frame memory`.

APIs returning `Frame_View(T)` or `Frame_String` expose borrowed frame data.
Read them with `frame_view_items` or `frame_string_value` while the originating
frame is open, and clone into an owner allocator before retaining the data.
Call `ui_frame_destroy` when a reusable frame leaves service. Deferred renderers
must finalize, consume borrowed output, and release in that order.

`ui_gfx.App_Session` is the default graphics host. It owns one runtime, reusable
frame, input/output pair, and adapter. It does not own widget/component state,
the graphics window, or `context.temp_allocator`. Advanced hosts may continue
to bracket these objects through the low-level adapter procedures.

## Composition and explicit escape hatches

Explicit ownership does not require applications to manage every coordinate.
The ordinary path combines a caller-owned `Ui`, explicit stable IDs, and
unsuffixed facade widgets. Facade dimensions are logical and widgets consume
bounded single-pass slots without retaining children or application state.

Use rect-based `*_at` widgets for canvases, scrolling content, overlays,
charts, and exact geometry. Use `Layout`, `Flow_Layout`, explicit measurement,
and visible-range rendering for custom composition. These paths change who
supplies geometry; they do not change caller ownership or identity.

## From immediate-mode library to app framework

The early success of IMGUI in game tools also narrowed how the idea came to be
perceived. A continuously rendered debug overlay can omit application concerns
such as idle scheduling, assistive technology, native text input, clipboard
integration, settings, and window lifetime. Those omissions describe the scope
of a particular library, not a limit of the immediate-mode interface.

Ingot's vision is to carry the single-path model through the complete app stack.
One evaluation derives the visible and machine-readable interface together:

```text
input snapshot
    -> application-owned state
    -> UI declaration
    -> layout + interaction + focus + semantics + paint
    -> platform output + accessibility bridge + WebGPU submission
```

`ingot:ui` stops at explicit renderer-independent data. `ingot:ui_gfx` connects
that data to graphics and platform services, while the other Ingot packages
provide the application shell around it. Accessibility is therefore not a
retained-tree exception: widgets emit a semantic snapshot with stable identity,
and the platform bridge may retain or compare snapshots without taking
ownership of the application's controls.

This combination is not claimed as unprecedented. Gio provides an immediate
application model with event-driven frames and semantic operations; egui
supports scheduled repaint and accessibility output through integrations.
Ingot's distinct goal is their class of application capability under a strict,
bounded, Odin-native ownership model and one WebGPU-oriented native/web stack.

## What rich UI behavior requires

A retained tree is one way to implement rich UI behavior, not a prerequisite
for it. Ingot implements the same classes of behavior by choosing explicit data
for each concern:

| Capability | Ingot's immediate-mode mechanism |
|---|---|
| Persistent controls | Caller-owned component structs |
| Dynamic layout | Bounded, single-pass layout with explicit measurements |
| Popups and modals | Per-frame overlay records plus bounded input claims |
| Keyboard focus | Stable caller-provided IDs and frame registration order |
| Accessibility | A semantic output buffer rebuilt with the interface |
| Animation | Caller/runtime state plus explicit redraw deadlines |
| Efficient idle | Event-driven rendering; no frame is built when nothing changes |
| Large data views | Application-owned data with visible-range rendering |

The result can provide the same user-facing behavior as a retained GUI without
making a retained widget tree the source of truth.

## Why this fits Tiger Style

Immediate mode makes the UI unusually compatible with Ingot's adaptation of
[Tiger Style](TIGER_STYLE.md):

- Ownership and lifetime are visible at call sites.
- Frame work, queues, buffers, and traversal can have named upper bounds.
- State transitions can be driven through public widget calls with synthetic
  input rather than reconstructed through an internal object graph.
- Derived frame output can be checked as data: focus links, routing claims,
  semantic nodes, draw batches, and resource generations.
- Deterministic seeds can replay the exact event sequence that violated an
  assertion.
- Assertions sit close to the boundaries they protect and turn corrupt state
  into an immediate, reproducible failure.

This matters most for UI machinery that should remain invisible to users:
routing, focus arbitration, overlay occlusion, text editing, accessibility
semantics, and GPU resource lifetime. Ingot can fuzz those systems headlessly
because their inputs and outputs are explicit. The framework does not need to
serialize, inspect, or repair a hidden widget hierarchy first.

The deeper consequence is that the architecture's boundary and the test
harness's boundary are the same boundary. Deterministic simulation needs a
function it can call, a small set of nondeterministic edges it can replace,
bounded work it can assert against, and derived output it can check as data. An
immediate-mode frame supplies all four without a testing layer being added on
top, so a harness drives production widgets rather than a parallel test-only
model. [Testing Ingot](testing.md) develops this argument, and
[the 3D content pipeline plan](3d-content-pipeline-plan.md) shows it being
applied to a subsystem before that subsystem is written.

Tiger Style does not make the system correct by declaration, and fuzzing does
not prove the absence of bugs. Together, explicit state, bounded work,
assertions, deterministic simulation, and sanitizer-backed tests make failures
smaller, earlier, and reproducible.

See [Testing](testing.md) for the harnesses and commands.

## Renderer boundary

`ingot:ui` does not import `ingot:gfx`. A frame consumes one explicit `Ui_Input`
snapshot and appends to bounded main and overlay paint lists plus platform and
semantic output. This makes interaction, focus, layout, wrapping, and painting
testable without a window or GPU.

`ingot:ui_gfx` is the default backend. It drains character input once, captures
window and pointer state, replays paint commands through `ingot:gfx`, owns the
font resources used for both measurement and drawing, and applies cursor,
clipboard, IME, redraw, and fullscreen requests. Other backends can implement
the same contracts without changing widgets.

The host frame order is capture input, begin UI, build widgets, end UI, replay
main then overlay paint, apply platform output, and end graphics drawing. Direct
application graphics that must interleave with UI use explicit replay points.

## The boundary

Ingot is not hostile to retained application data. Editors, documents, terminal
sessions, undo histories, and caches necessarily persist. Nor must every cache
or backing structure be exposed to application code. Text shaping, GPU resource
management, accessibility adapters, and platform integration may retain data
behind explicit service boundaries.

The distinction is authority and ownership:

> Immediate mode describes how the interface is declared and derived. It does
> not mean application state disappears or that the implementation is stateless.
> Ingot keeps persistent behavior in explicit caller-owned state and avoids a
> hidden framework-owned widget tree as the application's second source of truth.

This means Ingot can add multi-pass layout, virtualized views, richer text,
docking, animations, and semantic diffing without ceasing to be immediate-mode.
The test is not whether the framework remembers anything. The test is whether
application code must construct and synchronize a persistent widget model to
express the current interface.

The architecture has not proved every consequence merely by being coherent.
Complex text, large data views, docking, screen-reader continuity, asynchronous
updates, and long-lived product interfaces must be measured in real
applications. The vision is stronger than "immediate mode is good for tools": a
complete, accessible, energy-efficient product GUI can keep application state as
its single source of truth. Ingot's tests and examples must continue to prove
that claim workload by workload.

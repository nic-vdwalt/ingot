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
and presents the current interface each frame. The framework derives bounded
frame output from that declaration: draw commands, interactions, overlays,
focus registration, and accessibility semantics. There is no framework-owned
widget tree and no label-hashed state store.

This is not a claim that useful interfaces have no state. It is a claim that the
state should have an obvious owner.

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
into a hidden state database. Registration order can define traversal order
while application identity remains stable across insertion and reordering.

See [UI state and stable focus](ui-state.md) for ownership rules and concrete
Odin examples. [Choosing Ingot](comparison.md) compares this model with other
app engines and UI stacks.

## What retained-mode features require

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

Tiger Style does not make the system correct by declaration, and fuzzing does
not prove the absence of bugs. Together, explicit state, bounded work,
assertions, deterministic simulation, and sanitizer-backed tests make failures
smaller, earlier, and reproducible.

See [Testing](testing.md) for the harnesses and commands.

## The boundary

Ingot is not hostile to retained application data. Editors, documents, terminal
sessions, undo histories, and caches necessarily persist. The distinction is
ownership:

> Immediate mode describes how the interface is declared and derived. It does
> not mean application state disappears. Ingot keeps persistent behavior in
> explicit caller-owned state and avoids a hidden framework-owned widget tree.

That boundary keeps the UI a function of state the application can see, test,
and destroy.
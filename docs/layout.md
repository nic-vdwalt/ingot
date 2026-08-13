# Fit layout

`ingot:fit` exposes one bounded immediate builder. A draw callback receives an
open `^fit.Builder`, declares one root container, and balances every nested
container with `fit.End`.

`Row_With`, `Column_With`, `Flow_With`, `Grid_With`, and `Attachment_With` open
one container, invoke one caller procedure immediately, verify its nested
containers are balanced, and close the container. The procedure and userdata
are never retained. The manual open/`End` form remains available for dynamic
construction.

```odin
Draw :: proc(builder: ^fit.Builder, userdata: rawptr) {
	fit.Column(builder, {gap = .SM, padding = .LG})
	fit.Label(builder, "Settings", {role = .Title})
	fit.Row(builder, {gap = .SM, align = .Center})
	fit.Label(builder, "Actions", {track = fit.Grow()})
	fit.Button(builder, "save", "Save", &saved)
	fit.End(builder)
	fit.End(builder)
}
```

## Containers

- `Column` lays children on the vertical axis.
- `Row` lays children on the horizontal axis.
- `Flow` wraps measured children left to right.
- `Grid` uses fixed columns and a caller-selected row height.
- `Attachment` places exactly one out-of-flow child against a parent, root,
  screen rectangle, or viewport target.

Containers accept bounded spacing, padding, alignment, tracks, two-axis sizing,
background/border effects, clipping, and caller-owned transitions. Row and
Column direct children are bounded by `MAX_LAYOUT_FLEX`; total nodes and nesting
use fixed configured limits.

## Capacity and storage

A zero-value builder uses compile-time-configurable inline storage. The default
is `fit.STORAGE_NODE_DEFAULT` (128 nodes). Applications with a proven different
bound may attach reusable caller-owned storage up to
`fit.STORAGE_NODE_HARD_MAX` (8,192 nodes):

```odin
builder: fit.Builder
nodes: [1024]fit.Storage_Node
outputs: [1024]^bool
fit.Set_Storage(&builder, {nodes = nodes[:], outputs = outputs[:]})
```

Node and output slices must be non-nil, equal in length, and at least the layout
depth bound. Set or reset storage only while the builder is closed. The storage
must outlive every frame that uses it; do not copy an externally backed active
builder. `fit.Storage_Capacity` reports the selected capacity and
`fit.Reset_Storage` restores inline storage. Beginning a frame resets logical
counts and previously used output slots but never grows or retains a widget
hierarchy.

Larger capacity raises the bounded work available to one current-frame
description. Large data collections should still be chunked or virtualized.

## Tracks and size

`fit.Fit`, `fit.Grow`, `fit.Fixed`, and `fit.Percent` construct the one track
type. A leaf's `track` controls its parent main axis. `Size_Options` controls
width and height independently and can derive one axis from a positive integer
aspect ratio. Wrapped labels derive height after width assignment.

## Leaves

`Label` emits semantic text. `Button`, `Checkbox`, `Radio`, and `Slider` accept
stable string, `u64`, or explicit widget keys. Controls keep values in
caller-owned state and can publish activation or change into caller-owned
`^bool` output. Several leaves may share one output; results are OR-combined
after resetting the output for the current render.

`Custom` accepts bounded measure and render callbacks. Borrowed strings,
userdata, callbacks, state, and output pointers must remain valid until the
builder is rendered.

`Scope` composes an explicit string or nonzero integer component key around one
immediately invoked procedure. `Id` derives a current-frame `Widget_Id` from the
active scope. Neither API stores widget behavior; control values and interaction
state remain caller-owned.

## Measurement and placement

The application host renders automatically. Internal or advanced composition
may call `Measure` followed by `Render_At` to place a measured tree in a
caller-owned rectangle without consuming the root cursor. `Render` measures,
carves a content-sized slot, places, and renders synchronously.

The prepared layout engine remains internal and independently tested. There is
no public `Fit_Node` tree or direct `Prepared_Ui` construction path.

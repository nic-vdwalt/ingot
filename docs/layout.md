# Fit layout

`ingot:fit` exposes one bounded immediate builder. A draw callback receives an
open `^fit.Builder`, declares one root container, and balances every nested
container with `fit.End`.

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

## Tracks and size

`fit.Fit`, `fit.Grow`, `fit.Fixed`, and `fit.Percent` construct the one track
type. A leaf's `track` controls its parent main axis. `Size_Options` controls
width and height independently and can derive one axis from a positive integer
aspect ratio. Wrapped labels derive height after width assignment.

## Leaves

`Label` emits semantic text. `Button` accepts stable string, `u64`, or explicit
widget keys and can write activation into caller-owned `^bool` output. Several
buttons may share one output; results are OR-combined after resetting the output
for the current render.

`Custom` accepts bounded measure and render callbacks. Borrowed strings,
userdata, callbacks, and output pointers must remain valid until the builder is
rendered.

## Measurement and placement

The application host renders automatically. Internal or advanced composition
may call `Measure` followed by `Render_At` to place a measured tree in a
caller-owned rectangle without consuming the root cursor. `Render` measures,
carves a content-sized slot, places, and renders synchronously.

The prepared layout engine remains internal and independently tested. There is
no public `Fit_Node` tree or direct `Prepared_Ui` construction path.

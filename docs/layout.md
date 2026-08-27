# Fit layout

`ingot:fit` exposes one bounded immediate builder. A draw callback declares one
root container and receives a `fit.Parent` from it. Containers and leaves take
that Parent explicitly, so hierarchy is visible in ordinary values and there is
no open-container state to balance.

```odin
Draw :: proc(builder: ^fit.Builder, user_data: rawptr) {
	root := fit.Center(builder, {gap = .SM, padding = .LG})
	fit.Label(root, "Settings", {role = .Title})
	actions := fit.Row(root, {gap = .SM, align = .Center})
	fit.Label(actions, "Actions", {track = fit.Grow()})
	fit.Button(actions, "save", "Save", fit.action(Save))
}
```

A Parent is an opaque current-build capability. It identifies its Builder,
build generation, prepared parent node, and identity scope. It is allocation-free
and valid only during the draw that created it; never retain it in application
state or use it with another Builder. Stale and cross-Builder values assert
before changing the description.

## Dynamic composition

Containers return Parent values and do not change an ambient current parent.
This allows conditional layout and returning to an ancestor directly:

```odin
root := fit.Column(builder, {gap = .SM})
controls := fit.Row(root)
fit.Button(controls, "save", "Save", fit.action(Save))
fit.Label(root, "After controls")

content := fit.Row(root) if horizontal else fit.Column(root)
for item in items do fit.Label(content, item.label)
```

`fit.Scope(parent, key)` returns a Parent with the same layout node and a derived
identity seed. `fit.Id` and keyed controls derive identity from that seed:

```odin
for item, index in items {
	item_parent := fit.Scope(content, u64(index + 1))
	fit.Button(item_parent, "open", item.label)
}
```

Scope values do not add layout nodes or invoke callbacks.

## Activation timing

An `Action` is the primary prepared Button result. Fit dispatches it once, in
declaration order, after the complete tree renders in the activating frame.
Actions may mutate caller-owned state or enqueue work but cannot alter the
current prepared description. `Button_Delayed` uses zero-value caller-owned
`Signal` state when activation must instead be consumed during a later Builder
call. Signals and raw output pointers must outlive render.

## Containers

- `Center` is root-only shorthand for a Column with centered cross/main
  alignment and `Grow()` on both axes.
- `Column` lays children on the vertical axis.
- `Row` lays children on the horizontal axis.
- `Flow` wraps measured children left to right and can align, justify, or grow
  children independently on each bounded line.
- `Grid` supports the source-compatible uniform form or borrowed fixed, fit,
  grow, and percent tracks with deterministic placement and spans.
- `Attachment` places exactly one out-of-flow child against a target.
- `Scroll` clips and offsets exactly one child using caller-owned `Scroll_State`.
- `Section` returns a transparent Column after adding its title leaf.
- `Card` returns a token-styled Column.

Root-capable Row, Column, Flow, and Grid accept `^fit.Builder`; their child
overloads accept `fit.Parent`. Center accepts only Builder. Attachment and
Scroll accept Parent because they cannot be roots. Attachment and Scroll must
receive exactly one child; Fit validates this bounded invariant before measure
or render.

Containers accept bounded spacing, padding, alignment, tracks, two-axis sizing,
effects, clipping, and caller-owned transitions. Row and Column direct children
are bounded by `MAX_LAYOUT_FLEX`; total nodes and traversal depth use fixed
configured limits.

## Responsive flow

```odin
tags := fit.Flow(root, {
	gap_x = .SM,
	gap_y = .XS,
	align = .Center,
	justify = .Space_Between,
})
for tag in state.tags do fit.Button(tags, tag.id, tag.label)
```

Flow remains current-frame data. At most `fit.FLOW_GROW_ITEM_MAX` grow children
may occur on one line; ordinary wrapped children retain the existing bounded
flow capacity. Default start justification and stretch alignment preserve the
legacy geometry. A child's explicit `Grow()` track consumes the line's remaining
width without storing state across frames.

## Track grid

```odin
columns := [3]fit.Track{fit.Fixed(180), fit.Grow(), fit.Fit(120)}
grid := fit.Grid(root, {
	column_tracks = columns[:],
	row_height = 36,
	gap_x = .MD,
	gap_y = .SM,
})
fit.Label(grid, "Name")
wide := fit.Grid_Cell(grid, {column_span = 2})
fit.Label(wide, "Spans two columns")
```

Track slices are borrowed through synchronous render and must remain valid and
unchanged until rendering finishes. Grid placement is stable declaration-order
first-fit. Negative row or column values request automatic placement and zero
spans normalize to one. A `Grid_Cell` is a current-frame one-child wrapper, not
retained widget state. Grids are bounded by `fit.GRID_TRACK_MAX` tracks on each
axis and `fit.GRID_CELL_MAX` cells.

The legacy `{columns, row_height}` form remains available and retains its fixed
uniform-grid fast path. Choose either `columns` or `column_tracks`, never both.
Track grids use the generic measured path.

## Existing sizing and placement conveniences

Use `Size_Options.aspect` for aspect ratio, Track `min_size` and `max_size` for
constraints, container `padding` for inset content, and `Attachment` for overlay
or viewport-bound placement. These remain one vocabulary rather than aliases.

## Capacity and storage

A zero-value builder uses inline storage. The default is
`fit.STORAGE_NODE_DEFAULT` (128 nodes). Applications with a proven different
bound may attach reusable caller-owned storage up to
`fit.STORAGE_NODE_HARD_MAX` (8,192 nodes):

```odin
builder: fit.Builder
nodes: [1024]fit.Storage_Node
outputs: [1024]^bool
fit.Set_Storage(&builder, {nodes = nodes[:], outputs = outputs[:]})
```

Node and output slices must be non-nil, equal in length, and at least the layout
depth bound. Set or reset storage only while the builder is closed. Beginning a
frame resets logical counts and output slots but never grows or retains a widget
hierarchy.

## Tracks, leaves, and custom content

`fit.Fit`, `fit.Grow`, `fit.Fixed`, `fit.Percent`, and `fit.Hug` construct
tracks. A leaf's `track` controls its parent main axis; `Size_Options` controls
both axes. Default prepared children and explicit `Hug()` tracks use their
current-frame intrinsic measurement as the preferred main-axis size. Under
constraint, explicit `Fit` and `Grow` capacity compresses before Hug. If the
layout remains impossible, Hug compresses deterministically so geometry stays
inside the bounded parent. Use explicit `Fit` when content is intentionally
shrinkable before intrinsic controls.

`Label`, `Button`, `Checkbox`, `Radio`, `Slider`, `Text_Input`, `Progress`,
`Separator`, `Spacer`, table cells, `Canvas_Leaf`, and `Custom` consume Parent.
Controls keep values in caller-owned state. Prepared Button Actions live in
existing bounded node storage. `Custom` callbacks, borrowed strings, user_data,
state, signals, and output pointers must remain valid until render.

`Canvas` is the complete-root convenience for full-parent explicit geometry.
`Canvas_Leaf` places the same borrowed Surface callback in a measured Parent.
Neither callback nor Surface may be retained.

## Explicit Surface layout

The explicit-geometry layer remains separate. `Layout_Begin`, `Grid_Begin`,
`Flow_Begin`, and `Fit_Column_Begin` bind a borrowed Surface to caller-owned
state and retain their matching End calls:

```odin
layout: fit.Layout_State
fit.Layout_Begin(surface, &layout, rect, gap = fit.Px(surface, 8))
fit.Layout_Row(&layout, fit.Px(surface, 32))
left := fit.Layout_Next(&layout, fit.Px(surface, 120))
right := fit.Layout_Remaining(&layout)
fit.Layout_Pop(&layout)
fit.Layout_End(&layout)
```

These explicit states are reusable after End. Their physical rectangle results
must not pass through `Px` again.

Use `Vertical_Cursor_State` when authored Surface content flows downward. It
allocates each block before drawing it, so text, section headers, controls, and
spacers share one advancement rule instead of manually threading Y coordinates:

```odin
cursor: fit.Vertical_Cursor_State
fit.Vertical_Cursor_Begin(surface, &cursor, x, y, width, gap = fit.Px(surface, 8))
fit.Vertical_Cursor_Text(&cursor, "Status", .Label, .Secondary)
fit.Vertical_Cursor_Section_Header(&cursor, "DETAILS")
button_rect := fit.Vertical_Cursor_Next(&cursor, fit.Px(surface, 30))
_ = fit.Surface_Button(surface, button_id, "Continue", button_rect)
content := fit.Vertical_Cursor_End(&cursor)
```

Use `Vertical_Cursor_Begin_Bounded` when the cursor must stay inside a fixed
rectangle. `Vertical_Cursor_Remaining` and `Vertical_Cursor_Overflow` expose the
budget; semantic helpers do not draw partially granted rows. Cursor state is
zero-value ready, balanced, reusable after End, and never retained by Surface.

## Measurement and placement

The application host renders automatically. Internal or advanced composition
may call `Measure` followed by `Render_At`; `Render` measures, places, and
renders synchronously. The prepared engine remains internal: Parent is a
current-description capability, not a public retained node tree.

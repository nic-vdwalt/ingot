# Tables

`ingot:ui` provides interactive tables in the same caller-owned, bounded,
immediate-mode style as the rest of the toolkit. Column widths, display order,
visibility, sort, and scroll all live in a caller-owned `Table_State`; the
library retains nothing between frames. Every non-trivial decision (width
resolution, order moves, visibility, resize/reorder hit-testing, layout
serialization) is a pure procedure that is unit- and fuzz-tested without a
window or GPU.

There are two tiers:

- **Primitives** (`table_header`, `table_row_begin`/`table_row_end`,
  `table_tracks`, `table_sort_toggle`) — a sortable header plus shared column
  tracks. The caller owns the data, sorts it, and draws rows. These are
  unchanged and remain the lightest option.
- **Interactive tables** (`Table_State`, `table_header_ex`, `table_begin` /
  `table_row` / `table_end`, `table_visibility_menu`, and the
  `table_layout_encode`/`decode` codec) — resize, reorder, frozen header,
  borders/striping, hide/show, and persistence, all driven by one caller-owned
  `Table_State`.

## State model

```odin
columns := []ui.Table_Column{
    {label = "Name",  track = ui.grow(3, 0)},
    {label = "Count", track = ui.fixed(90), numeric = true},
    {label = "State", track = ui.grow(2, 0)},
}
table:  ui.Table_State   // caller-owned; seeded once, then mutated by the widgets
style := ui.table_style_default()
```

`Table_State` holds parallel arrays indexed by each column's **original** index
(its position in `columns`), plus an `order` array mapping a display slot to an
original index, the sort, the scroll offset, and the resize/reorder drag
latches. `table_style_default()` enables borders, inner gridlines, zebra
striping, resizing, reordering, hiding, and a `min_column_px` clamp.

Bounds: a table has at most `TABLE_COLUMN_COUNT_MAX` (32) columns. Overflow
asserts; degenerate rectangles drop through the frame's degenerate-drop path.

## Header only

`table_header_ex` draws the header in display order, sorts on click, resizes
when a border is dragged, and reorders when a header is dragged:

```odin
if ui.table_header_ex(u, "tbl", columns, &table, style) {
    // sort, a column width, or the order changed this frame
}
```

Resize and reorder share the single-drag-latch invariant with the rest of the
UI: at most one gesture runs per frame, a border press always wins over a
reorder, and a plain click still sorts. Column widths set by resizing are stored
in design units, so they scale with DPI like every other `Track`.

## Header + scrolling body

`table_begin` draws the sticky header and opens a scissored, virtual-scrolled
body over `count` fixed-height rows; the caller loops the visible window:

```odin
win := ui.table_begin(u, "tbl", columns, &table, style, 28, len(rows))
for i in win.first ..< min(win.first + win.visible_rows, len(rows)) {
    row := ui.table_row(u, &table, i, rows[i].name, selected = selected == i)
    if row.clicked do selected = i
    ui.cell(u, rows[i].name)
    ui.cell_value(u, fmt.tprintf("%d", rows[i].count))
    ui.cell(u, rows[i].state)
    ui.table_row_close(u)
}
ui.table_end(u, &table)
```

`table_row` paints the zebra background, selection/hover, and per-row horizontal
gridline, reports hover/click/double-click, and opens the header's column tracks
so cells land under their header. `table_end` closes the scissor and paints the
inner vertical gridlines and outer border from the same solved column edges, so
everything stays aligned across resize, reorder, and scroll. The header is drawn
above the scissor each frame, so it stays pinned while the body scrolls.

`freeze_cols` and `visible_h` are accepted by `table_begin`. `visible_h` caps
the body height. Horizontal scrolling is not yet engaged (columns are sized to
fit the body width via `grow`/`fixed`/`percent` or caller-measured `hug` tracks),
so leading columns are always visible; `freeze_cols` reserves the API for a
future horizontal-scroll mode.

Tables do not retain or scan body cells to discover a widest intrinsic column.
A table Hug track therefore carries a basis measured by the caller for the
current declaration. Interactive resizing continues to replace it with the
same explicit fixed-width override used for every other track kind.

## Hiding columns

`table_visibility_menu` renders a checkbox per column bound to the visibility
mask, applying each toggle through the guarded pure helper so the last visible
column can never be hidden:

```odin
if show_menu {
    _ = ui.table_visibility_menu(u, "cols", columns, &table)
}
```

Hidden columns are excluded from the solved layout, so the header, body, and
gridlines all skip them.

## Persistence

The persistable parts of a `Table_State` (widths, order, visibility, sort)
serialize to a caller-owned byte buffer with a pure, `core:*`-only codec. File
I/O lives in the app layer via `ingot:prefs`, keeping `ingot:ui` renderer- and
platform-independent:

```odin
// Save
blob := ui.table_layout_encode(&table, context.temp_allocator)
_ = prefs.write("my-app", "table-layout.txt", blob)

// Load (falls back to a fresh seed on a missing or drifted file)
if bytes, ok := prefs.read("my-app", "table-layout.txt", context.temp_allocator); ok {
    if !ui.table_layout_decode(bytes, &table, columns) {
        table.initialized = false
        ui.table_state_init(&table, columns)
    }
}
```

`table_layout_decode` validates the blob against the current column set — the
order must be a permutation, at least one column must remain visible, widths must
be non-negative, and the sort column must be in range — and leaves the target
untouched on any failure, so a changed column set can never corrupt the layout.

## Example

`examples/table_demo` is a complete `ui_gfx` application demonstrating resize,
reorder, sort, the visibility menu, and Save/Load layout persistence:

```sh
odin run examples/table_demo -collection:ingot=.
```

## Testing

The column model, resize/reorder/visibility math, and the serialization codec
are covered by pure unit tests (`table_state_test`, `table_prefs_test`), the
header and scroll interactions by frame-driven tests (`table_header_test`,
`table_scroll_test`, `table_menu_test`), and a deterministic fuzz test
(`table_fuzz_test`) drives random resize/reorder/hide/sort sequences, asserting
that `order` is always a permutation, at least one column stays visible, widths
stay non-negative, the solved layout matches visibility and order, and the
serialized form round-trips — every step, without a window.

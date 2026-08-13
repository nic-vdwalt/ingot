# Layout conventions

Ingot layout is caller-owned, bounded, and single-pass. Start with `Ui` for ordinary forms and panels. Use `Layout`, `Flow_Layout`, `Fit_Column`, `Grid`, and rect-based `*_at` widgets when geometry itself is application behavior.

## Tiers

A procedure's name tells you which category owns geometry and which units it expects. Each leaf-widget variant has one canonical geometry shape; `_state` and `_animated` distinguish behavior, not geometry.

| Category | Receiver | Units | Identity | Naming |
|---|---|---|---|---|
| **Facade leaf** | `u: ^Ui` | logical, scaled once | `Widget_Id` for interactive widgets; none for presentation | bare name - `button`, `spinner`, `tooltip` |
| **Explicit leaf** | `frame: ^Ui_Frame` | screen-space `Rect_I32` | caller-owned `Focus_Opt` where interactive | `*_at` - `button_at`, `line_chart_at` |
| **Explicit composition** | `^Ui_Frame` + caller state/config | screen-space named bounds | subsystem-owned | lifecycle/component names - `pane_begin`, `listbox_begin`, `context_menu` |
| **Paint/measurement** | explicit owner | screen-space or float paint geometry | none | verbs/subsystem prefix - `markdown_draw`, `overlay_*`, `measure_*` |
| **Explicit layout** | `l: ^Layout` | screen-space pixels | none | layout verbs - `layout_begin`, `push_row`, `next` |

Ordinary leaf widgets and simple presentation components have facade forms. Application-owned composition protocols - listbox, pane, modal, context menu, overlay, markdown, `Flow_Layout`, `Fit_Column`, and `Grid` - remain explicit by design.

No procedure that takes a `^Ui` carries a `ui_` prefix. `scripts/check_ui_api_layers.py` parses multiline declarations and enforces the category rules. The `ui_frame_*` and `ui_runtime_*` families are frame/runtime accessors and keep their prefix.

## Units

- **Design units** are unscaled numeric dimensions accepted by facade APIs. They cross `ui_frame_sc` or `ui_frame_scf` exactly once.
- **Screen-space pixels** are root and explicit `Rect_I32` values, layout output, measured text, `Ui_Metrics`, paint coordinates, and hit-test coordinates. They are already resolved and must not be scaled again.
- Explicit option structs contain screen-space values; a named facade boundary converts design-unit options before calling the explicit API.
- Fixed design-unit literals passed to low-level layout or `*_at` APIs use `ui_frame_sc` once.
- **Framebuffer pixels** are render attachment dimensions reached only at explicit backend conversion boundaries such as scissor setup.
- These 2D units are separate from the right-handed ROS 3D world basis (+X forward, +Y left, +Z up).
- `Space` tokens contain design units resolved once by `space_px`.
- Flex weights, percentages, animation fractions, and data values are dimensionless.

## Common composition

```odin
ui_gfx.app_ui_begin(app, frame, &form, gap = .SM)
ui.padding(&form, .LG)
ui.scope_begin(&form, "settings")

ui.flex_row_begin(
	&form,
	40,
	{ui.fit(120), ui.grow(), ui.fixed(96)},
	gap = .SM,
	align = .Center,
)
ui.label(&form, "Name")
_ = ui.text_input(
	&form,
	ui.id(&form, "name"),
	&name,
	"Name",
	semantics = {name = "Name"},
)
_ = ui.button(&form, ui.id(&form, "save"), "Save", .Primary)
ui.flex_row_end(&form)

ui.scope_end(&form)
ui.end(&form)
```

Ordinary `row_begin` and `column_begin` consume sizes as children are called. Flex variants resolve a bounded logical `Track` sequence up front. `fit(120)` is a caller-supplied basis; it does not inspect later children. A nested container consumes exactly one parent slot before opening its own frame.

Flex containers optionally take `justify` (`Main_Align`: `Start`, `Center`, `End`, `Space_Between`) to pack the resolved run along the main axis. Justification is a flex-only feature because only a declared run knows its total size before any child draws; free space exists only when no uncapped `grow` track absorbed it.

`end` returns the physical coordinate where the consumed content ends, including any trailing `space` token. Sections that chain on the explicit tier finish with `ui.space(u, .LG); return ui.end(u)` instead of re-deriving the cursor and adding a magic pad. For a root inside a scrolling pane, pass `ROOT_EXTENT_OPEN` as the root height: the pane owns the vertical bound, and `end` reports the extent `pane_end` needs.

Interactive facade widgets require caller-derived stable IDs. Labels are presentation and accessibility data, never identity.

Every row, column, flex container, and identity scope must close before `end`. Declared flex tracks must all be consumed. Unbalanced declarations are programmer errors.

## Custom slots

Facade widgets automatically consume an intrinsic slot or the next active flex track. Custom drawing uses an explicit slot procedure:

```odin
ui.row_begin(&form, 32)
rect := ui.slot_next(&form, 120, 32)
draw_custom(frame, rect)
ui.row_end(&form)

ui.flex_row_begin(&form, 40, {ui.grow(), ui.fixed(40)})
_ = ui.text_input(
	&form,
	ui.id(&form, "search"),
	&query,
	"Search",
	semantics = {name = "Search"},
)
icon_rect := ui.flex_slot_next(&form, 40)
draw_icon(frame, icon_rect)
ui.flex_row_end(&form)
```

`slot_next` is valid only without active flex tracks. `flex_slot_next` is valid only with active tracks. This keeps public custom geometry explicit even though standard widgets consume tracks automatically.

## Explicit flow

`Flow_Layout` places caller-sized items left to right and starts a new row before an item would exceed the available width. Rebuilding the declaration with a different width provides responsive reflow in one pass. It does not measure widgets, retain children, allocate, or recursively inspect content.

```odin
flow: ui.Flow_Layout
ui.flow_begin(&flow, bounds, gap_x, gap_y)
for item in items {
	size := measure_item(item)
	rect := ui.flow_next(&flow, size.x, size.y)
	draw_item(rect, item)
}
content := ui.flow_end(&flow)
```

One flow accepts at most `MAX_FLOW_ITEMS` items. Chunk or virtualize larger collections. `MAX_LAYOUT_FLEX` bounds one pre-resolved flex sequence, not ordinary slots, fit columns, or flow declarations.

## Explicit grid

`Grid` places caller-drawn cells on a fixed column count with a uniform row height, in row-major order. Column widths come from cumulative division, so every row spans the bounds exactly and no call site does per-cell x/y arithmetic. Gaps that do not fit a narrow bounds collapse cells to invisible (`slot_visible` is false) instead of trapping.

```odin
grid: ui.Grid
ui.grid_begin(&grid, bounds, cols, row_h, gap, gap)
for item in items {
	draw_item(ui.grid_next(&grid), item)
}
content := ui.grid_end(&grid)
```

One grid accepts at most `MAX_GRID_ITEMS` cells; chunk or virtualize larger collections.

## Measurement and explicit geometry

Intrinsic measurement is explicit: pass measured text or component extents to `fit`, `flow_next`, or `fit_column_next`. This keeps layout single-pass and avoids recursive measurement.

`Track` is the one sibling-size type, and `fit` / `grow` / `fixed` / `percent` are its one constructor set. The facade tier reads a `Track` in design units and scales it once; the `Layout` tier reads the same struct in screen-space pixels.

`Fit_Column` returns content-height bounds for caller-sized rows. Existing panes own scrolling and clipping; overlays use explicit `*_at` geometry. Compose those facilities instead of adding a second scroll or overlay state model to layout.

Use rect-based `*_at` for canvases, scroll-offset content, overlays, custom hit regions, and geometry whose exact placement is application behavior. Both facade and explicit entry points share interaction, focus, semantics, and paint; they differ only in who supplies the rectangle.

`Flow_Layout`, `Fit_Column`, and `Grid` have no facade entry point by design: all exist so the caller can drive placement itself, which is the opposite of what carving a slot from a container does.

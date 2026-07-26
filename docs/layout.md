# Layout conventions

Ingot layout is caller-owned, bounded, single-pass, and integer-pixel based. `Layout` remains the low-level physical geometry engine. `Ui` adds named spacing and composition conveniences for ordinary forms.

## Units

- Screen rectangles, parent rectangles, measured text, and `Ui_Metrics` are already physical values.
- Fixed literals passed to low-level layout or `*_at` APIs use `ui_frame_sc` once.
- `Space` tokens (`None`, `XS`, `SM`, `MD`, `LG`, `XL`) are logical values resolved once by `ui_space_px`.
- Flex weights, percentages, animation fractions, and data values are dimensionless and are never scaled.

## Common composition

```odin
ui.ui_begin_frame(&form, frame, x, y, w, h)
ui.ui_padding(&form, ui.ui_insets(&form, .LG))
ui.ui_row_begin(
	&form,
	32,
	{ui.flex_fixed(ui.ui_frame_sc(frame, 120)), ui.flex_grow()},
	{gap = .SM, align = .Center},
)
left := ui.ui_flex_slot(&form, ui.ui_frame_metrics(frame).ROW_H_MD)
right := ui.ui_flex_slot(&form, ui.ui_frame_metrics(frame).ROW_H_MD)
ui.ui_row_end(&form)
ui.ui_end(&form)
```

`ui_row_begin` and `ui_column_begin` resolve their bounded child-size sequence up front. End every row, column, panel, and ID scope before `ui_end`; unbalanced scopes are programmer errors.

`ui_panel_begin/end`, `ui_spacer`, `ui_separator`, `ui_remaining`, and `ui_compact` are thin conveniences over the same layout. `ui_compact` only compares available width with a scaled breakpoint; it does not trigger implicit reflow.

## Explicit flow

`Flow_Layout` places caller-sized items left to right and starts a new row before an item would exceed the available width. Rebuilding the same declaration with a different width provides responsive reflow in one pass. The flow does not measure widgets, retain children, allocate, or recursively inspect content. Oversized item widths clamp to the flow width; heights remain unclipped so the returned content extent can drive scrolling.

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

One flow accepts at most `MAX_FLOW_ITEMS` items. Chunk or virtualize larger collections. The 32-item `MAX_LAYOUT_FLEX` bound applies only to one pre-resolved flex sibling sequence, not to ordinary slots, fit columns, or flow declarations.

## Measurement and containers

Intrinsic measurement is explicit: pass measured text or component extents to `flex_fit`, `flow_next`, or `fit_column_next`. Text helpers provide unwrapped width and wrapped width/height. This keeps layout single-pass and avoids recursive measurement.

`Fit_Column` returns content-height bounds for caller-sized rows. Existing panes own scrolling and clipping; overlays use explicit `*_at` geometry. Compose those facilities with flow instead of nesting a second scroll or overlay state model inside layout.

Use `*_at` for canvases, scroll-offset content, overlays, charts, and geometry whose exact placement is part of application behavior. Use `*_ui` for forms and panels where widgets should consume bounded slots.

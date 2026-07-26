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

Use `*_at` for canvases, scroll-offset content, overlays, charts, and geometry whose exact placement is part of application behavior. Use `*_ui` for forms and panels where widgets should consume bounded slots.

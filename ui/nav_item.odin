package ui

// nav_item_at draws one navigation row: selected accent bar, icon, label, and
// an optional muted right-aligned badge (for example a shortcut hint). It
// shares the button interaction path, so pointer click, keyboard activation,
// focus ring, and cursor feedback behave exactly as a Ghost button does.
//
// Semantics are a Button carrying .Selected, so assistive technology
// announces which section is current. The caller owns `selected`; the widget
// only reports activation.
nav_item_at :: proc(
	frame: ^Ui_Frame,
	rect: Rect_I32,
	icon: Icon,
	label: string,
	selected: bool,
	badge: string = "",
	focus: Focus_Opt = {},
	widget: Widget_Id = WIDGET_ID_NONE,
) -> bool {
	assert(frame != nil && frame.open, "nav_item_at: invalid frame")
	assert(label != "", "nav_item_at: empty label")
	if ui_frame_drop_degenerate(frame, rect.w <= 0 || rect.h <= 0) do return false
	interaction := interact(frame, rect_f32(rect))
	focus_opt_click(frame, focus, rect.x, rect.y, rect.w, rect.h)
	clicked := interaction.clicked || focus_opt_activated(frame, focus, .Button, widget)
	if interaction.hovered do request_cursor(frame, .POINTING_HAND)
	if !rect_culled_frame(frame, rect) {
		nav_item_paint(frame, rect, icon, label, selected, interaction.hovered, badge)
		if focus_opt_focused(focus) do draw_focus_ring(frame, rect.x, rect.y, rect.w, rect.h)
	}
	semantics: Sem_State
	if selected do semantics += {.Selected}
	semantic_push(frame, .Button, rect, label, semantics, focus, widget = widget)
	return clicked
}

@(private = "file")
nav_item_paint :: proc(
	frame: ^Ui_Frame,
	rect: Rect_I32,
	icon: Icon,
	label: string,
	selected, hovered: bool,
	badge: string,
) {
	assert(frame != nil && frame.open, "nav_item_paint: invalid frame")
	assert(rect.w > 0 && rect.h > 0, "nav_item_paint: empty rect")
	theme := ui_frame_theme(frame)
	list_row_bg_at(frame, rect, selected, hovered)
	pad := ui_frame_sc(frame, 8)
	if selected {
		bar_h := max(rect.h - pad, 1)
		bar := Rect_I32{rect.x, rect.y + (rect.h - bar_h) / 2, ui_frame_sc(frame, 3), bar_h}
		draw_rounded_fill(frame, rect_f32(bar), .SM, theme.fg_accent)
	}
	ink := Ink.Accent if selected else Ink.Primary
	if !selected && !hovered do ink = .Secondary
	color := text_ink(frame, ink)
	size := ui_frame_metrics(frame).FONT_SIZE_LABEL
	icon_side := min(rect.h - ui_frame_sc(frame, 4), ui_frame_sc(frame, 20))
	icon_rect := Rect_I32{rect.x + pad, rect.y + (rect.h - icon_side) / 2, icon_side, icon_side}
	if icon_side > 0 do draw_icon_frame(frame, icon, icon_rect, color)
	text_x := icon_rect.x + icon_side + pad
	text_right := rect.x + rect.w - pad
	if badge != "" {
		badge_size := ui_frame_metrics(frame).FONT_SIZE_NOTE
		badge_w := measure_text_string_frame(frame, badge, badge_size)
		badge_x := text_right - badge_w
		if badge_x > text_x + pad {
			badge_y := frame_text_center_y(frame, rect.y, rect.h, badge_size)
			draw_text_string_frame(
				frame,
				badge,
				badge_x,
				badge_y,
				badge_size,
				text_ink(frame, .Muted),
			)
			text_right = badge_x - pad
		}
	}
	text_y := frame_text_center_y(frame, rect.y, rect.h, size)
	text_ink_color := text_ink(frame, .Heading) if selected else text_ink(frame, .Primary)
	draw_text_truncated_frame(
		frame,
		label,
		text_x,
		text_y,
		max(text_right - text_x, 0),
		size,
		text_ink_color,
	)
}

// NAV_ITEM_FILL_W asks the layout for the full cross extent: slot_px clamps
// an intrinsic width to the available track, so any value wider than a
// screen yields a row that fills its column.
NAV_ITEM_FILL_W :: i32(1 << 20)

// nav_item is the facade form: one full-width row of ROW_H_MD in the current
// slot, focus-registered under the stable `id`.
nav_item :: proc(
	u: ^Ui,
	id: Widget_Id,
	icon: Icon,
	label: string,
	selected: bool,
	badge: string = "",
) -> bool {
	assert(u != nil && u.open, "nav_item: frame not open")
	assert(id != WIDGET_ID_NONE, "nav_item: zero stable id")
	rect := slot_next_px(u, NAV_ITEM_FILL_W, ui_frame_metrics(u.frame).ROW_H_MD)
	fo := focus(u, id) if slot_visible(rect) else Focus_Opt{}
	return nav_item_at(u.frame, rect, icon, label, selected, badge, fo, id)
}

// Facade cells: ellipsis-truncated text for table and list columns. Unlike
// label (which scissors-clips), a cell guarantees its text fits the slot by
// truncating with an ellipsis, so dense multi-column rows never bleed into
// their neighbours.
package ui

// cell draws truncated text into the next layout slot. Inside a flex track
// run it consumes one full track; outside it carves an intrinsic-width slot
// (where truncation is a no-op by construction).
cell :: proc(
	u: ^Ui,
	text: string,
	role: Text_Role = .Body,
	ink: Ink = .Primary,
	trunc: Truncate_Side = .Tail,
) {
	assert(u != nil && u.open, "cell: frame not open")
	assert(u.frame != nil, "cell: nil frame")
	metrics := ui_frame_metrics(u.frame)
	font_size := text_role_size(u.frame, role)
	color := text_ink(u.frame, ink)
	intrinsic_w := measure_text_string_frame(u.frame, text, font_size)
	r := slot_next_px(u, intrinsic_w, metrics.LINE_HEIGHT)
	if !slot_visible(r) {
		_ = ui_frame_drop_degenerate(u.frame, true)
		return
	}
	// Truncation guarantees the painted text fits; the inset keeps a cell's
	// glyphs from touching the next column.
	inset := ui_frame_sc(u.frame, 4)
	fitted := truncate_to_width_dir_frame(u.frame, text, max(r.w - inset, 0), font_size, trunc)
	draw_text_string_frame(u.frame, fitted, r.x, r.y + (r.h - font_size) / 2, font_size, color)
	semantic_push(u.frame, .Label, r, text, {})
}

// cell_left is cell with a leading ellipsis, keeping the tail of long paths
// visible ("…libs/ingot").
cell_left :: proc(u: ^Ui, text: string, role: Text_Role = .Body, ink: Ink = .Primary) {
	assert(u != nil && u.open, "cell_left: frame not open")
	assert(u.frame != nil, "cell_left: nil frame")
	cell(u, text, role, ink, .Head)
}

// cell_value right-aligns truncated text in its slot — the reading direction
// for numeric table columns.
cell_value :: proc(u: ^Ui, text: string, role: Text_Role = .Body, ink: Ink = .Primary) {
	assert(u != nil && u.open, "cell_value: frame not open")
	assert(u.frame != nil, "cell_value: nil frame")
	metrics := ui_frame_metrics(u.frame)
	font_size := text_role_size(u.frame, role)
	color := text_ink(u.frame, ink)
	intrinsic_w := measure_text_string_frame(u.frame, text, font_size)
	r := slot_next_px(u, intrinsic_w, metrics.LINE_HEIGHT)
	if !slot_visible(r) {
		_ = ui_frame_drop_degenerate(u.frame, true)
		return
	}
	inset := ui_frame_sc(u.frame, 4)
	fitted := truncate_to_width_dir_frame(u.frame, text, max(r.w - inset, 0), font_size, .Tail)
	fitted_w := measure_text_string_frame(u.frame, fitted, font_size)
	x := r.x + max(r.w - inset - fitted_w, 0)
	draw_text_string_frame(u.frame, fitted, x, r.y + (r.h - font_size) / 2, font_size, color)
	semantic_push(u.frame, .Label, r, text, {})
}

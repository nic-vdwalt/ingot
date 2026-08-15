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
	font_size := text_role_size(u.frame, role)
	intrinsic_w := measure_text_string_frame(u.frame, text, font_size)
	r := slot_next_px(u, intrinsic_w, ui_frame_metrics(u.frame).LINE_HEIGHT)
	cell_at(u.frame, r, text, role, ink, trunc)
}

cell_at :: proc(
	frame: ^Ui_Frame,
	rect: Rect_I32,
	text: string,
	role: Text_Role = .Body,
	ink: Ink = .Primary,
	trunc: Truncate_Side = .Tail,
	numeric: bool = false,
) {
	assert(frame != nil && frame.open, "cell_at: invalid frame")
	if !slot_visible(rect) {
		_ = ui_frame_drop_degenerate(frame, true)
		return
	}
	font_size := text_role_size(frame, role)
	inset := ui_frame_sc(frame, 4)
	fitted := truncate_to_width_dir_frame(frame, text, max(rect.w - inset, 0), font_size, trunc)
	fitted_w := measure_text_string_frame(frame, fitted, font_size)
	x := rect.x
	if numeric do x = rect.x + max(rect.w - inset - fitted_w, 0)
	draw_text_string_frame(
		frame,
		fitted,
		x,
		rect.y + (rect.h - font_size) / 2,
		font_size,
		text_ink(frame, ink),
	)
	semantic_push(frame, .Label, rect, text, {})
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
	font_size := text_role_size(u.frame, role)
	intrinsic_w := measure_text_string_frame(u.frame, text, font_size)
	r := slot_next_px(u, intrinsic_w, ui_frame_metrics(u.frame).LINE_HEIGHT)
	cell_at(u.frame, r, text, role, ink, numeric = true)
}

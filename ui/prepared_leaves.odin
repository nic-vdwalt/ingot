package ui

Prepared_Text_Input :: struct {
	id:          Widget_Id,
	box:         ^Input_Box,
	placeholder: string,
	height:      i32,
	masked:      bool,
	semantics:   Text_Input_Semantics,
}

Prepared_Progress :: struct {
	value:   f32,
	ink:     Ink,
	height:  i32,
	options: Progress_Bar_Options,
}

Prepared_Spacer :: struct {
	space:      Space,
	horizontal: bool,
}

Prepared_Table_Cell :: struct {
	text:    string,
	role:    Text_Role,
	ink:     Ink,
	trunc:   Truncate_Side,
	numeric: bool,
}

prepared_text_input_size :: proc(u: ^Ui, spec: Prepared_Text_Input) -> Intrinsic_Size {
	assert(u != nil && u.open && u.frame != nil, "prepared text input size: invalid UI")
	assert(spec.id != WIDGET_ID_NONE && spec.box != nil, "prepared text input size: invalid spec")
	metrics := ui_frame_metrics(u.frame)
	height := metrics.ROW_H_MD + metrics.CONTROL_GAP
	if spec.height > 0 do height = ui_frame_sc(u.frame, spec.height)
	return intrinsic_leaf(0, height)
}

prepared_text_input_at :: proc(u: ^Ui, spec: Prepared_Text_Input, rect: Rect_I32) -> bool {
	assert(u != nil && u.open && u.frame != nil, "prepared text input: invalid UI")
	assert(spec.id != WIDGET_ID_NONE && spec.box != nil, "prepared text input: invalid spec")
	assert(spec.semantics.name != "", "prepared text input: empty accessible label")
	fo := focus(u, spec.id) if slot_visible(rect) else Focus_Opt{}
	focus_opt_click(u.frame, fo, rect.x, rect.y, rect.w, rect.h)
	semantics := spec.semantics
	semantics.focus = fo.focus
	semantics.focus_id = fo.id
	semantics.widget = spec.id
	return text_input_at(
		u.frame,
		rect,
		spec.box,
		spec.placeholder,
		focus_opt_focused(fo),
		spec.masked,
		semantics,
	)
}

prepared_progress_size :: proc(u: ^Ui, spec: Prepared_Progress) -> Intrinsic_Size {
	assert(u != nil && u.open && u.frame != nil, "prepared progress size: invalid UI")
	assert(spec.value >= 0 && spec.value <= 1, "prepared progress size: invalid value")
	height := spec.height
	if height == 0 do height = 8
	assert(height > 0, "prepared progress size: invalid height")
	return intrinsic_leaf(0, ui_frame_sc(u.frame, height))
}

prepared_progress_at :: proc(u: ^Ui, spec: Prepared_Progress, rect: Rect_I32) {
	assert(u != nil && u.open && u.frame != nil, "prepared progress: invalid UI")
	assert(spec.value >= 0 && spec.value <= 1, "prepared progress: invalid value")
	progress_bar_at(u.frame, rect, spec.value, text_ink(u.frame, spec.ink), spec.options)
}

prepared_separator_size :: proc(u: ^Ui) -> Intrinsic_Size {
	assert(u != nil && u.open && u.frame != nil, "prepared separator size: invalid UI")
	return intrinsic_leaf(0, 1)
}

prepared_separator_at :: proc(u: ^Ui, rect: Rect_I32) {
	assert(u != nil && u.open && u.frame != nil, "prepared separator: invalid UI")
	if !slot_visible(rect) do return
	draw_rectangle_rec(u.frame, rect_f32(rect), ui_frame_theme(u.frame).border_subtle)
}

prepared_spacer_size :: proc(u: ^Ui, spec: Prepared_Spacer) -> Intrinsic_Size {
	assert(u != nil && u.open && u.frame != nil, "prepared spacer size: invalid UI")
	pixels := space_px(u, spec.space)
	if spec.horizontal do return intrinsic_leaf(pixels, 0)
	return intrinsic_leaf(0, pixels)
}

prepared_table_cell_size :: proc(u: ^Ui, spec: Prepared_Table_Cell) -> Intrinsic_Size {
	assert(u != nil && u.open && u.frame != nil, "prepared table cell size: invalid UI")
	assert(spec.text != "", "prepared table cell size: empty text")
	font_size := text_role_size(u.frame, spec.role)
	width := measure_text_string_frame(u.frame, spec.text, font_size)
	return intrinsic_leaf(width, ui_frame_metrics(u.frame).LINE_HEIGHT)
}

prepared_table_cell_at :: proc(u: ^Ui, spec: Prepared_Table_Cell, rect: Rect_I32) {
	assert(u != nil && u.open && u.frame != nil, "prepared table cell: invalid UI")
	assert(spec.text != "", "prepared table cell: empty text")
	cell_at(u.frame, rect, spec.text, spec.role, spec.ink, spec.trunc, spec.numeric)
}

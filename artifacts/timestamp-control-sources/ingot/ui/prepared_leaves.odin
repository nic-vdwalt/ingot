package ui

import "core:strings"

Prepared_Text_Input :: struct {
	id:          Widget_Id,
	box:         ^Input_Box,
	// Caller-owned buffer variant: when text+state are set (and box is nil),
	// the widget renders app-owned state via text_input_box instead of a
	// bundled Input_Box. This lets declarative fit reuse state the app already
	// holds, matching immediate mode's caller-owns-state contract.
	text:        ^strings.Builder,
	state:       ^Text_Input_State,
	placeholder: string,
	height:      i32,
	masked:      bool,
	semantics:   Text_Input_Semantics,
}

// A prepared text input is fed by exactly one source: a bundled Input_Box, or a
// caller-owned (strings.Builder, Text_Input_State) pair. Enforcing XOR here
// keeps the widget forgiving about *where* its state lives while rejecting a
// nil/ambiguous binding that would render a blank field.
prepared_text_input_source_ok :: proc(spec: Prepared_Text_Input) -> bool {
	has_box := spec.box != nil
	has_buffer := spec.text != nil && spec.state != nil
	return has_box != has_buffer
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
	assert(
		spec.id != WIDGET_ID_NONE && prepared_text_input_source_ok(spec),
		"prepared text input size: invalid spec",
	)
	metrics := ui_frame_metrics(u.frame)
	height := metrics.ROW_H_MD + metrics.CONTROL_GAP
	if spec.height > 0 do height = ui_frame_sc(u.frame, spec.height)
	return intrinsic_leaf(0, height)
}

prepared_text_input_at :: proc(u: ^Ui, spec: Prepared_Text_Input, rect: Rect_I32) -> bool {
	assert(u != nil && u.open && u.frame != nil, "prepared text input: invalid UI")
	assert(
		spec.id != WIDGET_ID_NONE && prepared_text_input_source_ok(spec),
		"prepared text input: invalid spec",
	)
	assert(spec.semantics.name != "", "prepared text input: empty accessible label")
	fo := focus(u, spec.id) if slot_visible(rect) else Focus_Opt{}
	focus_opt_click(u.frame, fo, rect.x, rect.y, rect.w, rect.h)
	semantics := spec.semantics
	semantics.focus = fo.focus
	semantics.focus_id = fo.id
	semantics.widget = spec.id
	if spec.text != nil && spec.state != nil {
		cfg := Text_Input_Config {
			rect         = rect,
			placeholder  = spec.placeholder,
			active       = focus_opt_focused(fo),
			masked       = spec.masked,
			enable_pills = true,
			enable_undo  = true,
			submit       = text_input_default_submit(u.frame, rect.h),
			semantics    = semantics,
		}
		return text_input_box(u.frame, cfg, spec.text, spec.state)
	}
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

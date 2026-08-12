package ui

import "core:strings"

MAX_OVERLAY_CMDS :: PAINT_COMMAND_CAP
OVERLAY_TEXT_CAP :: PAINT_TEXT_CAP

Overlay_State :: struct {
	open: bool,
}

// DEPRECATED: use layer_begin. overlay_begin survives one release as a thin
// wrapper: a claiming group becomes a layer with a claim rect, a passive group
// becomes a paint-only layer at the same z.
overlay_begin :: proc(frame: ^Ui_Frame, rect: Rectangle, claim_input: bool, z: Z_Order = Z_POPUP) {
	assert(frame != nil && frame.open, "overlay_begin: invalid frame")
	assert(!frame.overlay.open, "overlay_begin: group already open")
	assert(rect.width >= 0 && rect.height >= 0, "overlay_begin: negative rect")
	claim := claim_input ? rect : Rectangle{}
	layer_begin(frame, z, claim)
	frame.overlay.open = true
}

// DEPRECATED: use layer_end.
overlay_end :: proc(frame: ^Ui_Frame) {
	assert(frame != nil && frame.open, "overlay_end: invalid frame")
	assert(frame.overlay.open, "overlay_end: no group open")
	layer_end(frame)
	frame.overlay.open = false
}

// DEPRECATED: use draw_rectangle_rec inside a layer.
overlay_rect :: proc(frame: ^Ui_Frame, rect: Rectangle, color: Color) {
	assert(frame != nil, "overlay_rect: nil frame")
	assert(frame.overlay.open, "overlay_rect: group not open")
	draw_rectangle_rec(frame, rect, color)
}

// DEPRECATED: use draw_rectangle_lines_ex inside a layer.
overlay_rect_lines :: proc(frame: ^Ui_Frame, rect: Rectangle, thickness: f32, color: Color) {
	assert(frame != nil, "overlay_rect_lines: nil frame")
	assert(frame.overlay.open, "overlay_rect_lines: group not open")
	draw_rectangle_lines_ex(frame, rect, thickness, color)
}

// DEPRECATED: use draw_rectangle_rounded inside a layer.
overlay_rounded :: proc(
	frame: ^Ui_Frame,
	rect: Rectangle,
	roundness: f32,
	segments: i32,
	color: Color,
) {
	assert(frame != nil, "overlay_rounded: nil frame")
	assert(frame.overlay.open, "overlay_rounded: group not open")
	draw_rectangle_rounded(frame, rect, roundness, segments, color)
}

// DEPRECATED: use draw_rectangle_rounded_lines_ex inside a layer.
overlay_rounded_lines :: proc(
	frame: ^Ui_Frame,
	rect: Rectangle,
	roundness: f32,
	segments: i32,
	thickness: f32,
	color: Color,
) {
	assert(frame != nil, "overlay_rounded_lines: nil frame")
	assert(frame.overlay.open, "overlay_rounded_lines: group not open")
	draw_rectangle_rounded_lines_ex(frame, rect, roundness, segments, thickness, color)
}

// DEPRECATED: use draw_line_ex inside a layer.
overlay_line :: proc(frame: ^Ui_Frame, p0, p1: Vector2, color: Color) {
	assert(frame != nil, "overlay_line: nil frame")
	assert(frame.overlay.open, "overlay_line: group not open")
	draw_line_ex(frame, p0, p1, 1, color)
}

// DEPRECATED: use draw_text_string inside a layer.
overlay_text :: proc(frame: ^Ui_Frame, text: string, x, y, font_size: i32, color: Color) {
	assert(frame != nil, "overlay_text: nil frame")
	assert(frame.overlay.open, "overlay_text: group not open")
	draw_text_string(frame, text, x, y, font_size, color)
}

overlay_cmd_count :: proc(frame: ^Ui_Frame) -> int {
	assert(frame != nil && frame.output != nil, "overlay_cmd_count: invalid frame")
	return frame.output.overlay.count
}

// overlay_dropped reports commands the overlay list refused for capacity; text
// overflow is counted separately in output.overlay.dropped_text_bytes.
overlay_dropped :: proc(frame: ^Ui_Frame) -> int {
	assert(frame != nil, "overlay_dropped: nil frame")
	assert(frame.output != nil, "overlay_dropped: missing output")
	return frame.output.overlay.dropped_commands
}

overlay_reset :: proc(frame: ^Ui_Frame) {
	assert(frame != nil && frame.output != nil, "overlay_reset: invalid frame")
	paint_list_reset(&frame.output.overlay)
	frame.overlay = {}
}

overlay_flush :: proc(frame: ^Ui_Frame) {
	assert(frame != nil, "overlay_flush: nil frame")
	assert(!frame.overlay.open, "overlay_flush: group still open")
}

// DEPRECATED: use draw_text_string inside a layer.
overlay_text_str :: proc(
	frame: ^Ui_Frame,
	sb: ^strings.Builder,
	x, y, font_size: i32,
	color: Color,
) {
	assert(sb != nil, "overlay_text_str: nil builder")
	overlay_text(frame, strings.to_string(sb^), x, y, font_size, color)
}

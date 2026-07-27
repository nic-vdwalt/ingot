package ui

import "core:strings"

MAX_OVERLAY_CMDS :: PAINT_COMMAND_CAP
OVERLAY_TEXT_CAP :: PAINT_TEXT_CAP

Overlay_State :: struct {
	open:    bool,
	dropped: int,
}

overlay_begin :: proc(frame: ^Ui_Frame, rect: Rectangle, claim_input: bool) {
	assert(frame != nil && frame.open, "overlay_begin: invalid frame")
	assert(!frame.overlay.open, "overlay_begin: group already open")
	assert(rect.width >= 0 && rect.height >= 0, "overlay_begin: negative rect")
	frame.overlay.open = true
	if claim_input do route_claim(frame, rect)
}

overlay_end :: proc(frame: ^Ui_Frame) {
	assert(frame != nil && frame.open, "overlay_end: invalid frame")
	assert(frame.overlay.open, "overlay_end: no group open")
	frame.overlay.open = false
}

overlay_list :: proc(frame: ^Ui_Frame) -> ^Paint_List {
	assert(frame != nil && frame.open, "overlay_list: invalid frame")
	assert(frame.overlay.open, "overlay_list: group not open")
	return frame_paint_list(frame, .Overlay)
}

overlay_rect :: proc(frame: ^Ui_Frame, rect: Rectangle, color: Color) {
	assert(frame != nil, "overlay_rect: nil frame")
	command := Paint_Command {
		kind  = .Rectangle,
		rect  = rect,
		color = color,
	}
	if !paint_push(overlay_list(frame), command) do frame.overlay.dropped += 1
}

overlay_rect_lines :: proc(frame: ^Ui_Frame, rect: Rectangle, thickness: f32, color: Color) {
	assert(frame != nil, "overlay_rect_lines: nil frame")
	command := Paint_Command {
		kind      = .Rectangle_Outline,
		rect      = rect,
		thickness = thickness,
		color     = color,
	}
	if !paint_push(overlay_list(frame), command) do frame.overlay.dropped += 1
}

overlay_rounded :: proc(
	frame: ^Ui_Frame,
	rect: Rectangle,
	roundness: f32,
	segments: i32,
	color: Color,
) {
	assert(frame != nil, "overlay_rounded: nil frame")
	command := Paint_Command {
		kind      = .Rectangle_Rounded,
		rect      = rect,
		roundness = roundness,
		segments  = segments,
		color     = color,
	}
	if !paint_push(overlay_list(frame), command) do frame.overlay.dropped += 1
}

overlay_rounded_lines :: proc(
	frame: ^Ui_Frame,
	rect: Rectangle,
	roundness: f32,
	segments: i32,
	thickness: f32,
	color: Color,
) {
	assert(frame != nil, "overlay_rounded_lines: nil frame")
	command := Paint_Command {
		kind      = .Rectangle_Rounded_Outline,
		rect      = rect,
		roundness = roundness,
		segments  = segments,
		thickness = thickness,
		color     = color,
	}
	if !paint_push(overlay_list(frame), command) do frame.overlay.dropped += 1
}

overlay_line :: proc(frame: ^Ui_Frame, p0, p1: Vector2, color: Color) {
	assert(frame != nil, "overlay_line: nil frame")
	command := Paint_Command {
		kind      = .Line,
		p0        = p0,
		p1        = p1,
		thickness = 1,
		color     = color,
	}
	if !paint_push(overlay_list(frame), command) do frame.overlay.dropped += 1
}

overlay_text :: proc(frame: ^Ui_Frame, text: string, x, y, font_size: i32, color: Color) {
	assert(frame != nil, "overlay_text: nil frame")
	font := Font_Id(0)
	if text_backend_valid(frame.runtime.text_backend) {
		font = text_backend_font(frame.runtime.text_backend, font_size)
	}
	command := Paint_Command {
		kind      = .Text,
		p0        = {f32(x), f32(y)},
		font      = font,
		font_size = f32(font_size),
		color     = color,
	}
	if !paint_push_text(overlay_list(frame), command, text) do frame.overlay.dropped += 1
}

overlay_cmd_count :: proc(frame: ^Ui_Frame) -> int {
	assert(frame != nil && frame.output != nil, "overlay_cmd_count: invalid frame")
	return frame.output.overlay.count
}

overlay_dropped :: proc(frame: ^Ui_Frame) -> int {
	assert(frame != nil, "overlay_dropped: nil frame")
	return frame.overlay.dropped
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

overlay_text_str :: proc(
	frame: ^Ui_Frame,
	sb: ^strings.Builder,
	x, y, font_size: i32,
	color: Color,
) {
	assert(sb != nil, "overlay_text_str: nil builder")
	overlay_text(frame, strings.to_string(sb^), x, y, font_size, color)
}

package ui_gfx

import rl "ingot:gfx"
import "ingot:ui"

FONT_CAP :: 64

Adapter :: struct {
	fonts:       [FONT_CAP]rl.Font,
	font_sizes:  [FONT_CAP]i32,
	font_count:  int,
	initialized: bool,
}

vec_to_ui :: proc(value: rl.Vector2) -> ui.Vec2 {
	return {value.x, value.y}
}

vec_to_gfx :: proc(value: ui.Vec2) -> rl.Vector2 {
	return {value.x, value.y}
}

rect_to_gfx :: proc(value: ui.Rect) -> rl.Rectangle {
	return {value.x, value.y, value.width, value.height}
}

color_to_gfx :: proc(value: ui.Color) -> rl.Color {
	return rl.Color{value.r, value.g, value.b, value.a}
}

color_from_gfx :: proc(value: rl.Color) -> ui.Color {
	return ui.Color{value.r, value.g, value.b, value.a}
}

adapter_init :: proc(adapter: ^Adapter) {
	assert(adapter != nil, "adapter_init: nil adapter")
	assert(!adapter.initialized, "adapter_init: already initialized")
	adapter.initialized = true
}

adapter_destroy :: proc(adapter: ^Adapter) {
	assert(adapter != nil, "adapter_destroy: nil adapter")
	for index in 0 ..< adapter.font_count {
		if adapter.fonts[index].glyphCount > 0 do rl.UnloadFont(adapter.fonts[index])
	}
	adapter^ = {}
}

adapter_begin_frame :: proc(
	adapter: ^Adapter,
	frame: ^ui.Ui_Frame,
	runtime: ^ui.Ui_Runtime,
	input: ^ui.Ui_Input,
	output: ^ui.Ui_Output,
) {
	assert(adapter != nil && adapter.initialized, "adapter_begin_frame: invalid adapter")
	assert(
		frame != nil && runtime != nil && input != nil && output != nil,
		"adapter_begin_frame: nil argument",
	)
	capture_input(input)
	frame.output = output
	ui.ui_frame_begin(frame, runtime, input)
}

adapter_end_frame :: proc(adapter: ^Adapter, frame: ^ui.Ui_Frame) {
	assert(adapter != nil && adapter.initialized, "adapter_end_frame: invalid adapter")
	assert(frame != nil && frame.output != nil, "adapter_end_frame: invalid frame")
	ui.ui_frame_end(frame)
	replay(adapter, frame.output)
	apply_platform_output(&frame.output.platform)
}

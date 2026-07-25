package ui_gfx

import rl "ingot:gfx"
import "ingot:ui"

FONT_CAP :: 64

Adapter :: struct {
	gfx_context:     ^rl.Context,
	gfx_epoch:       u64,
	fonts:           [FONT_CAP]rl.Font,
	font_sizes:      [FONT_CAP]i32,
	font_count:      int,
	font_dpi:        f32,
	font_codepoints: []rune,
	initialized:     bool,
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
	adapter_init_context(adapter, rl.default_context())
}

adapter_init_context :: proc(adapter: ^Adapter, gfx_context: ^rl.Context) {
	assert(adapter != nil, "adapter_init_context: nil adapter")
	assert(gfx_context != nil, "adapter_init_context: nil graphics context")
	assert(!adapter.initialized, "adapter_init_context: already initialized")
	adapter.gfx_context = gfx_context
	adapter.gfx_epoch = rl.context_epoch(gfx_context)
	adapter.font_dpi = 1
	adapter.initialized = true
	adapter_text_init(adapter)
}

adapter_attach_runtime :: proc(adapter: ^Adapter, runtime: ^ui.Ui_Runtime) {
	assert(adapter != nil && adapter.initialized, "adapter_attach_runtime: invalid adapter")
	assert(runtime != nil && runtime.initialized, "adapter_attach_runtime: invalid runtime")
	ui.ui_runtime_set_text_backend(runtime, adapter_text_backend(adapter))
}

adapter_destroy :: proc(adapter: ^Adapter) {
	assert(adapter != nil && adapter.initialized, "adapter_destroy: invalid adapter")
	adapter_reset_fonts(adapter)
	delete(adapter.font_codepoints)
	adapter^ = {}
}

adapter_paint_sink :: proc(list: ^ui.Paint_List, command: ui.Paint_Command, userdata: rawptr) {
	adapter := (^Adapter)(userdata)
	assert(adapter != nil && adapter.initialized, "adapter_paint_sink: invalid adapter")
	assert(list != nil, "adapter_paint_sink: nil list")
	replay_command(adapter, list, command)
}

adapter_begin_frame :: proc(
	adapter: ^Adapter,
	frame: ^ui.Ui_Frame,
	runtime: ^ui.Ui_Runtime,
	input: ^ui.Ui_Input,
	output: ^ui.Ui_Output,
) {
	assert(adapter != nil && adapter.initialized, "adapter_begin_frame: invalid adapter")
	assert(adapter.gfx_context != nil, "adapter_begin_frame: nil graphics context")
	assert(
		adapter.gfx_epoch == rl.context_epoch(adapter.gfx_context),
		"adapter_begin_frame: stale graphics context",
	)
	assert(
		frame != nil && runtime != nil && input != nil && output != nil,
		"adapter_begin_frame: nil argument",
	)
	capture_input(input)
	adapter_attach_runtime(adapter, runtime)
	when ODIN_OS == .Darwin || ODIN_OS == .JS {
		adapter_set_font_dpi(adapter, input.dpi_scale)
	} else {
		adapter_set_font_dpi(adapter, 1)
	}
	frame.output = output
	ui.paint_list_set_sink(&output.main, adapter_paint_sink, adapter)
	ui.ui_frame_begin(frame, runtime, input)
}

adapter_end_frame :: proc(adapter: ^Adapter, frame: ^ui.Ui_Frame) {
	assert(adapter != nil && adapter.initialized, "adapter_end_frame: invalid adapter")
	assert(frame != nil && frame.output != nil, "adapter_end_frame: invalid frame")
	output := frame.output
	ui.ui_frame_finalize(frame)
	replay_list(adapter, &output.overlay)
	apply_platform_output(&output.platform)
	ui.paint_list_set_sink(&output.main, nil, nil)
	ui.ui_frame_release(frame)
}

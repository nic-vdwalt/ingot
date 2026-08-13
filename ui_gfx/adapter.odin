package ui_gfx

// UI rendering borrows context.temp_allocator for frame scratch. The host owns
// that arena and must reclaim it after each complete frame.

import ak "ingot:accesskit"
import rl "ingot:gfx"
import "ingot:ui"

FONT_CAP :: 64

Adapter :: struct {
	gfx_context:      ^rl.Context,
	gfx_epoch:        u64,
	fonts:            [FONT_CAP]rl.Font,
	font_sizes:       [FONT_CAP]i32,
	font_count:       int,
	font_dpi:         f32,
	font_codepoints:  []rune,
	a11y_snapshot:    ui.Sem_Frame,
	a11y_focus:       ak.Node_Id,
	a11y_initialized: bool,
	initialized:      bool,
	graphics_open:    bool,
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
	adapter.a11y_initialized = adapter_a11y_init(adapter)
	assert(adapter.initialized)
	assert(adapter.gfx_context == gfx_context)
	assert(adapter.gfx_epoch == rl.context_epoch(gfx_context))
}

adapter_attach_runtime :: proc(adapter: ^Adapter, runtime: ^ui.Ui_Runtime) {
	assert(adapter != nil && adapter.initialized, "adapter_attach_runtime: invalid adapter")
	assert(runtime != nil && runtime.initialized, "adapter_attach_runtime: invalid runtime")
	ui.ui_runtime_set_text_backend(runtime, adapter_text_backend(adapter))
	ui.ui_runtime_set_web_form_backend(runtime, adapter_web_form_backend())
}

// adapter_web_form_backend bridges the ui web-form hooks to the gfx browser
// overlay. Installed on every target: outside JS the gfx procs are no-op
// stubs, so the bridge costs nothing while keeping call sites unconditional.
adapter_web_form_backend :: proc() -> ui.Web_Form_Backend {
	return ui.Web_Form_Backend {
		sync_text_input = adapter_web_form_sync_text,
		sync_submit_button = adapter_web_form_sync_submit,
	}
}

@(private = "file")
adapter_web_form_sync_text :: proc(
	data: rawptr,
	form_id, field_id, name, placeholder, value: string,
	x, y, w, h, input_type, autocomplete: i32,
	active: bool,
) -> ui.Web_Form_Text_Result {
	_ = data
	result := rl.SyncWebTextInput(
		form_id,
		field_id,
		name,
		placeholder,
		value,
		x,
		y,
		w,
		h,
		input_type,
		autocomplete,
		active,
	)
	return {result.value, result.cursor, result.changed, result.focused}
}

@(private = "file")
adapter_web_form_sync_submit :: proc(
	data: rawptr,
	form_id, label: string,
	x, y, w, h, style, font_size: i32,
	enabled: bool,
) -> bool {
	_ = data
	return rl.SyncWebSubmitButton(form_id, label, x, y, w, h, style, font_size, enabled)
}

adapter_destroy :: proc(adapter: ^Adapter) {
	assert(adapter != nil && adapter.initialized, "adapter_destroy: invalid adapter")
	assert(!adapter.graphics_open, "adapter_destroy: graphics frame still open")
	adapter_a11y_destroy(adapter)
	adapter_reset_fonts(adapter)
	delete(adapter.font_codepoints)
	adapter^ = {}
	assert(!adapter.initialized)
	assert(!adapter.graphics_open)
}

adapter_paint_sink :: proc(list: ^ui.Paint_List, command: ui.Paint_Command, userdata: rawptr) {
	adapter := (^Adapter)(userdata)
	assert(adapter != nil && adapter.initialized, "adapter_paint_sink: invalid adapter")
	assert(adapter.graphics_open, "adapter_paint_sink: no open graphics frame")
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
	adapter_prepare_frame(adapter, runtime, input)
	adapter_open_frame(adapter, frame, runtime, input, output)
}

adapter_prepare_frame :: proc(adapter: ^Adapter, runtime: ^ui.Ui_Runtime, input: ^ui.Ui_Input) {
	assert(adapter != nil && adapter.initialized, "adapter_prepare_frame: invalid adapter")
	assert(adapter.gfx_context != nil, "adapter_prepare_frame: nil graphics context")
	when ODIN_OS != .JS {
		assert(
			adapter.gfx_epoch == rl.context_epoch(adapter.gfx_context),
			"adapter_prepare_frame: stale graphics context",
		)
	}
	assert(runtime != nil && input != nil, "adapter_prepare_frame: nil argument")
	capture_input_context(adapter.gfx_context, input)
	adapter_attach_runtime(adapter, runtime)
	when ODIN_OS == .Darwin || ODIN_OS == .JS {
		adapter_set_font_dpi(adapter, input.dpi_scale)
	} else {
		adapter_set_font_dpi(adapter, 1)
	}
}

adapter_open_frame :: proc(
	adapter: ^Adapter,
	frame: ^ui.Ui_Frame,
	runtime: ^ui.Ui_Runtime,
	input: ^ui.Ui_Input,
	output: ^ui.Ui_Output,
) {
	assert(adapter != nil && adapter.initialized, "adapter_open_frame: invalid adapter")
	assert(
		frame != nil && runtime != nil && input != nil && output != nil,
		"adapter_open_frame: nil argument",
	)
	frame.output = output
	ui.paint_list_set_sink(&output.main, adapter_paint_sink, adapter)
	ui.ui_frame_begin(frame, runtime, input)
	assert(frame.open)
	assert(frame.output == output)
	adapter_a11y_poll(adapter, frame)
}

adapter_end_frame :: proc(adapter: ^Adapter, frame: ^ui.Ui_Frame) {
	assert(adapter != nil && adapter.initialized, "adapter_end_frame: invalid adapter")
	assert(frame != nil && frame.output != nil, "adapter_end_frame: invalid frame")
	when ODIN_OS != .JS {
		assert(
			adapter.gfx_epoch == rl.context_epoch(adapter.gfx_context),
			"adapter_end_frame: stale context",
		)
	}
	output := frame.output
	ui.ui_frame_finalize(frame)
	adapter_a11y_publish(adapter, frame)
	if adapter.graphics_open {
		replay_list_tiered(adapter, &output.overlay)
	} else {
		assert(output.overlay.count == 0, "adapter_end_frame: overlay without graphics frame")
	}
	apply_platform_output_context(adapter.gfx_context, &output.platform)
	ui.paint_list_set_sink(&output.main, nil, nil)
	ui.ui_frame_release(frame)
	when ODIN_OS != .JS do assert(adapter.initialized)
}

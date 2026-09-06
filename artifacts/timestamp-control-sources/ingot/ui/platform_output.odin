package ui

PLATFORM_TEXT_CAP :: 4096
PLATFORM_CONTROL_CAP :: 256

Platform_Control_Kind :: enum u8 {
	Text_Input,
	Submit_Button,
	Semantic_Control,
}

Platform_Control :: struct {
	kind:        Platform_Control_Kind,
	id:          u64,
	rect:        Rect,
	text_offset: int,
	text_length: int,
	focused:     bool,
	disabled:    bool,
}

// Frame_Strategy mirrors gfx.Frame_Strategy so renderer-independent UI code can
// express a pacing decision without importing the renderer. ui_gfx asserts the
// two declarations stay in the same order.
Frame_Strategy :: enum u8 {
	Continuous,
	Event_Driven,
}

Platform_Output :: struct {
	cursor:                   Cursor,
	cursor_requested:         bool,
	clipboard_text:           [PLATFORM_TEXT_CAP]u8,
	clipboard_text_len:       int,
	clipboard_write:          bool,
	text_input_rect:          Rect,
	text_input_active:        bool,
	request_redraw:           bool,
	redraw_after:             f64,
	// frame_strategy_requested gates frame_strategy the way cursor_requested
	// gates cursor. platform_output_reset zeroes the struct every frame, so an
	// ungated field would read as .Continuous and stomp the strategy of an app
	// that manages pacing itself.
	frame_strategy:           Frame_Strategy,
	frame_strategy_requested: bool,
	toggle_fullscreen:        bool,
	controls:                 [PLATFORM_CONTROL_CAP]Platform_Control,
	control_count:            int,
	controls_dropped:         int,
	control_text:             [PLATFORM_TEXT_CAP]u8,
	control_text_len:         int,
}

// platform_set_frame_strategy publishes a pacing decision for the adapter to
// apply at end of frame. Callers should only call this on a transition: the
// renderer's SetFrameStrategy marks activity internally, so re-requesting the
// same strategy every frame refills the settle burst and the app never idles.
platform_set_frame_strategy :: proc(output: ^Platform_Output, strategy: Frame_Strategy) {
	assert(output != nil, "platform_set_frame_strategy: nil output")
	output.frame_strategy = strategy
	output.frame_strategy_requested = true
}

platform_output_reset :: proc(output: ^Platform_Output) {
	assert(output != nil, "platform_output_reset: nil output")
	output^ = {}
	output.cursor = .DEFAULT
}

platform_set_clipboard :: proc(output: ^Platform_Output, text: string) -> bool {
	assert(output != nil, "platform_set_clipboard: nil output")
	if len(text) > PLATFORM_TEXT_CAP {
		output.clipboard_write = false
		return false
	}
	copy(output.clipboard_text[:], transmute([]u8)text)
	output.clipboard_text_len = len(text)
	output.clipboard_write = true
	return true
}

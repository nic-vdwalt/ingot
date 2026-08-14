package ui_gfx

import "core:strings"
import rl "ingot:gfx"
import "ingot:ui"

// ui.Frame_Strategy mirrors rl.Frame_Strategy so renderer-independent UI code
// can name a pacing decision. The cast below is only sound while the two
// declarations stay in the same order.
#assert(int(ui.Frame_Strategy.Continuous) == int(rl.Frame_Strategy.Continuous))
#assert(int(ui.Frame_Strategy.Event_Driven) == int(rl.Frame_Strategy.Event_Driven))
#assert(len(ui.Frame_Strategy) == len(rl.Frame_Strategy))

apply_platform_output_context :: proc(ctx: ^rl.Context, output: ^ui.Platform_Output) {
	assert(ctx != nil && output != nil, "apply_platform_output_context: nil argument")
	if output.cursor_requested do rl.context_set_mouse_cursor(ctx, rl.MouseCursor(output.cursor))
	if output.clipboard_write {
		text := string(output.clipboard_text[:output.clipboard_text_len])
		value := strings.clone_to_cstring(text, context.temp_allocator)
		rl.context_set_clipboard_text(ctx, value)
	}
	if output.text_input_active {
		rect := output.text_input_rect
		rl.context_set_text_input_rect(
			ctx,
			i32(rect.x),
			i32(rect.y),
			i32(rect.width),
			i32(rect.height),
		)
	}
	when ODIN_OS == .JS {
		if output.toggle_fullscreen do rl.context_toggle_fullscreen(ctx)
	}
	// Strategy before the redraw requests: SetFrameStrategy marks activity, so
	// applying it after would let a settle burst outlive a deadline set this
	// frame. Producers only publish this on a transition (see ui.pacer_frame).
	if output.frame_strategy_requested {
		rl.context_set_frame_strategy(ctx, rl.Frame_Strategy(output.frame_strategy))
	}
	if output.request_redraw do rl.RequestRedrawContext(ctx)
	if output.redraw_after > 0 do rl.RequestRedrawInContext(ctx, output.redraw_after)
}

package ui_gfx

import "core:strings"
import rl "ingot:gfx"
import "ingot:ui"

apply_platform_output :: proc(output: ^ui.Platform_Output) {
	assert(output != nil, "apply_platform_output: nil output")
	if output.cursor_requested do rl.SetMouseCursor(rl.MouseCursor(output.cursor))
	if output.clipboard_write {
		text := string(output.clipboard_text[:output.clipboard_text_len])
		rl.SetClipboardText(strings.clone_to_cstring(text, context.temp_allocator))
	}
	if output.text_input_active {
		rect := output.text_input_rect
		rl.SetTextInputRect(i32(rect.x), i32(rect.y), i32(rect.width), i32(rect.height))
	}
	when ODIN_OS == .JS {
		if output.toggle_fullscreen do rl.ToggleFullscreen()
	}
	if output.request_redraw do rl.RequestRedraw()
	if output.redraw_after > 0 do rl.RequestRedrawIn(output.redraw_after)
}

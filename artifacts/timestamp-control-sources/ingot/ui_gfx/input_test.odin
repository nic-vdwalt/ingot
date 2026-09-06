#+build !js
package ui_gfx

import "core:strings"
import "core:testing"
import rl "ingot:gfx"
import "ingot:ui"

@(test)
clipboard_snapshot_owns_bounded_bytes :: proc(t: ^testing.T) {
	adapter: Adapter
	input: ui.Ui_Input
	source := strings.repeat("x", ui.INPUT_CLIPBOARD_CAP + 8, context.temp_allocator)
	snapshot_clipboard(&adapter, &input, source)
	copy(adapter.clipboard[:4], "safe")
	testing.expect_value(t, len(input.clipboard), ui.INPUT_CLIPBOARD_CAP)
	testing.expect_value(t, input.clipboard[:4], "safe")
}

@(test)
pointer_snapshot_copies_values_and_overflow :: proc(t: ^testing.T) {
	source: [2]rl.Pointer_Event
	source[0] = {
		id           = 7,
		position     = {10, 20},
		pressure     = 0.75,
		buttons      = 1,
		kind         = .Down,
		pointer_type = .Pen,
		button       = .Left,
		primary      = true,
	}
	source[1] = {
		id           = 7,
		position     = {11, 22},
		kind         = .Cancel,
		pointer_type = .Pen,
		button       = .None,
	}
	input: ui.Ui_Input
	snapshot_pointer_events(&input, source[:], true)
	testing.expect_value(t, input.pointer_event_count, 2)
	testing.expect_value(t, input.pointer_events[0].id, ui.Pointer_Id(7))
	testing.expect_value(t, input.pointer_events[0].pressure, f32(0.75))
	testing.expect_value(t, input.pointer_events[1].kind, ui.Pointer_Event_Kind.Cancel)
	testing.expect(t, input.pointer_events_overflowed)
}

@(test)
platform_output_validation_rejects_invalid_bounds :: proc(t: ^testing.T) {
	output: ui.Platform_Output
	testing.expect(t, platform_output_valid(&output))
	output.clipboard_text_len = ui.PLATFORM_TEXT_CAP + 1
	testing.expect(t, !platform_output_valid(&output))
	output = {}
	output.cursor_requested = true
	output.cursor = ui.Cursor(999)
	testing.expect(t, !platform_output_valid(&output))
	output = {}
	output.frame_strategy_requested = true
	output.frame_strategy = ui.Frame_Strategy(99)
	testing.expect(t, !platform_output_valid(&output))
}

#+build !js
package ui_gfx

import "core:strings"
import "core:testing"
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

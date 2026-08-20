#+build !js
package ui_gfx

import "core:testing"
import "ingot:ui"

@(test)
input_clip_utf8_preserves_rune_boundaries :: proc(t: ^testing.T) {
	text := "abc€z"
	testing.expect_value(t, input_clip_utf8(text, 3), 3)
	testing.expect_value(t, input_clip_utf8(text, 4), 3)
	testing.expect_value(t, input_clip_utf8(text, 6), 6)
	testing.expect_value(t, input_clip_utf8(text, 99), len(text))
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

#+build !js
package fit

import "core:testing"

fit_expect_diagnostics :: proc(
	t: ^testing.T,
	actual: Frame_Diagnostics,
	expected: Frame_Diagnostics,
	frame_index: int,
	seed: u64,
	loc := #caller_location,
) {
	actual_values := [14]i32 {
		actual.input_characters_dropped,
		actual.degenerate_widgets_dropped,
		actual.layout_overflows,
		actual.unsupported_glyphs,
		actual.semantic_nodes_dropped,
		actual.semantic_focus_dropped,
		actual.semantic_actions_dropped,
		actual.semantic_id_collisions,
		actual.semantic_text_truncations,
		actual.main_commands_dropped,
		actual.main_text_bytes_dropped,
		actual.overlay_commands_dropped,
		actual.overlay_text_bytes_dropped,
		actual.platform_controls_dropped,
	}
	expected_values := [14]i32 {
		expected.input_characters_dropped,
		expected.degenerate_widgets_dropped,
		expected.layout_overflows,
		expected.unsupported_glyphs,
		expected.semantic_nodes_dropped,
		expected.semantic_focus_dropped,
		expected.semantic_actions_dropped,
		expected.semantic_id_collisions,
		expected.semantic_text_truncations,
		expected.main_commands_dropped,
		expected.main_text_bytes_dropped,
		expected.overlay_commands_dropped,
		expected.overlay_text_bytes_dropped,
		expected.platform_controls_dropped,
	}
	names := [14]string {
		"input_characters_dropped",
		"degenerate_widgets_dropped",
		"layout_overflows",
		"unsupported_glyphs",
		"semantic_nodes_dropped",
		"semantic_focus_dropped",
		"semantic_actions_dropped",
		"semantic_id_collisions",
		"semantic_text_truncations",
		"main_commands_dropped",
		"main_text_bytes_dropped",
		"overlay_commands_dropped",
		"overlay_text_bytes_dropped",
		"platform_controls_dropped",
	}
	for value, index in actual_values {
		testing.expectf(
			t,
			value == expected_values[index],
			"frame %d seed %d: %s expected %d, observed %d",
			frame_index,
			seed,
			names[index],
			expected_values[index],
			value,
			loc = loc,
		)
	}
	if actual_values == expected_values {
		testing.expect_value(t, actual, expected, loc)
	}
}

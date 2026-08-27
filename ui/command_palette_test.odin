#+build !js
package ui

import "core:testing"
import "ingot:action"

@(test)
command_palette_matches_bounded_metadata :: proc(t: ^testing.T) {
	item := Command_Palette_Item {
		command = action.Command_Id(1),
		label = "Save Document",
		description = "Writes the active file",
		keywords = "persist disk",
	}
	testing.expect(t, command_palette_match(item, "SAVE"))
	testing.expect(t, command_palette_match(item, "active"))
	testing.expect(t, command_palette_match(item, "DISK"))
	testing.expect(t, !command_palette_match(item, "close"))
}

@(test)
command_palette_filter_preserves_source_order :: proc(t: ^testing.T) {
	items := [3]Command_Palette_Item {
		{command = action.Command_Id(1), label = "Save"},
		{command = action.Command_Id(2), label = "Close"},
		{command = action.Command_Id(3), label = "Save All"},
	}
	state: Command_Palette_State
	matches := command_palette_filter(&state, items[:], "save")
	testing.expect_value(t, len(matches), 2)
	testing.expect_value(t, matches[0], 0)
	testing.expect_value(t, matches[1], 2)
}

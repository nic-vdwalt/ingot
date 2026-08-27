package ui

import "core:strings"
import "ingot:action"

COMMAND_PALETTE_ITEM_MAX :: 256

Command_Palette_Item :: struct {
	command:     action.Command_Id,
	label:       string,
	description: string,
	keywords:    string,
	disabled:    bool,
}

Command_Palette_State :: struct {
	query:       Input_Box,
	selected:    int,
	window:      int,
	match_count: int,
	matches:     [COMMAND_PALETTE_ITEM_MAX]int,
}

command_palette_state_destroy :: proc(state: ^Command_Palette_State) {
	assert(state != nil, "command_palette_state_destroy: nil state")
	input_box_destroy(&state.query)
	state^ = {}
}

command_palette_match :: proc(item: Command_Palette_Item, query: string) -> bool {
	if query == "" do return true
	lowered := strings.to_lower(query, context.temp_allocator)
	label := strings.to_lower(item.label, context.temp_allocator)
	if strings.contains(label, lowered) do return true
	description := strings.to_lower(item.description, context.temp_allocator)
	if strings.contains(description, lowered) do return true
	keywords := strings.to_lower(item.keywords, context.temp_allocator)
	return strings.contains(keywords, lowered)
}

command_palette_filter :: proc(
	state: ^Command_Palette_State,
	items: []Command_Palette_Item,
	query: string,
) -> []int {
	assert(state != nil, "command_palette_filter: nil state")
	assert(len(items) <= COMMAND_PALETTE_ITEM_MAX, "command_palette_filter: too many items")
	state.match_count = 0
	for item, index in items {
		assert(
			item.command != action.COMMAND_ID_NONE && item.label != "",
			"command palette: invalid item",
		)
		for previous in 0 ..< index {
			assert(items[previous].command != item.command, "command palette: duplicate command")
		}
		if command_palette_match(item, query) {
			state.matches[state.match_count] = index
			state.match_count += 1
		}
	}
	state.selected = clamp(state.selected, 0, max(state.match_count - 1, 0))
	state.window = clamp(state.window, 0, max(state.match_count - 1, 0))
	return state.matches[:state.match_count]
}

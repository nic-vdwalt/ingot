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

// COMMAND_PALETTE_VISIBLE_MAX bounds the rows drawn per frame. The match list
// scrolls through `window`, so the palette's height never depends on how many
// commands an application registers.
COMMAND_PALETTE_VISIBLE_MAX :: 8
COMMAND_PALETTE_MODAL_ID :: Modal_Id(0x434D_4450_414C)

Command_Palette_Result :: struct {
	activated: action.Command_Id,
	dismissed: bool,
}

Command_Palette_Options :: struct {
	title:       string,
	placeholder: string,
	empty_note:  string,
}

@(private = "file")
command_palette_config :: proc(frame: ^Ui_Frame) -> Modal_Config {
	assert(frame != nil && frame.open, "command_palette_config: invalid frame")
	metrics := ui_frame_metrics(frame)
	viewport := frame_viewport(frame)
	assert(viewport.w >= 0 && viewport.h >= 0, "command_palette_config: negative viewport")
	rows := i32(COMMAND_PALETTE_VISIBLE_MAX)
	height :=
		ui_frame_sc(frame, 40) +
		metrics.PADDING * 3 +
		metrics.ROW_H_MD * (rows + 1) +
		metrics.CONTROL_GAP
	return {
		placement = .Center,
		size = {max(min(ui_frame_sc(frame, 560), viewport.w - metrics.PADDING * 4), 1), height},
		screen = viewport,
		dismiss = {.Escape, .Outside_Click},
	}
}

// command_palette_keys moves the selection with Up/Down (clamped, repeat
// aware) and keeps it inside the visible window. Home/End stay with the query
// input, where they move the caret.
@(private = "file")
command_palette_keys :: proc(frame: ^Ui_Frame, state: ^Command_Palette_State) {
	assert(frame != nil && frame.open, "command_palette_keys: invalid frame")
	assert(state != nil, "command_palette_keys: nil state")
	last := max(state.match_count - 1, 0)
	if is_key_pressed_or_repeat(frame, .DOWN) {
		key_pressed_consume(frame, .DOWN)
		state.selected = min(state.selected + 1, last)
	}
	if is_key_pressed_or_repeat(frame, .UP) {
		key_pressed_consume(frame, .UP)
		state.selected = max(state.selected - 1, 0)
	}
	if state.selected < state.window do state.window = state.selected
	if state.selected >= state.window + COMMAND_PALETTE_VISIBLE_MAX {
		state.window = state.selected - COMMAND_PALETTE_VISIBLE_MAX + 1
	}
}

@(private = "file")
command_palette_row :: proc(
	frame: ^Ui_Frame,
	rect: Rect_I32,
	item: Command_Palette_Item,
	selected: bool,
	position, total: int,
) -> bool {
	assert(frame != nil && frame.open, "command_palette_row: invalid frame")
	assert(rect.w > 0 && rect.h > 0, "command_palette_row: empty rect")
	interaction := interact(frame, rect_f32(rect))
	enabled := !item.disabled
	if enabled && interaction.hovered do request_cursor(frame, .POINTING_HAND)
	if !rect_culled_frame(frame, rect) {
		list_row_bg_at(frame, rect, selected, enabled && interaction.hovered)
		metrics := ui_frame_metrics(frame)
		pad := metrics.PADDING
		size := metrics.FONT_SIZE_LABEL
		label_ink := Ink.Disabled if !enabled else (Ink.Heading if selected else Ink.Primary)
		y := frame_text_center_y(frame, rect.y, rect.h, size)
		label_w := min(measure_text_string_frame(frame, item.label, size), rect.w / 2)
		draw_text_truncated_frame(
			frame,
			item.label,
			rect.x + pad,
			y,
			label_w,
			size,
			text_ink(frame, label_ink),
		)
		note_x := rect.x + pad * 2 + label_w
		note_w := rect.x + rect.w - pad - note_x
		if item.description != "" && note_w > pad {
			note_size := metrics.FONT_SIZE_NOTE
			note_y := frame_text_center_y(frame, rect.y, rect.h, note_size)
			draw_text_truncated_frame(
				frame,
				item.description,
				note_x,
				note_y,
				note_w,
				note_size,
				text_ink(frame, .Muted),
			)
		}
	}
	semantics: Sem_State
	if selected do semantics += {.Selected}
	if !enabled do semantics += {.Disabled}
	semantic_push(
		frame,
		.Option,
		rect,
		item.label,
		semantics,
		description = item.description,
		position_in_set = position + 1,
		size_of_set = total,
	)
	return enabled && interaction.clicked
}

// command_palette_draw renders an open palette as a modal: query input, the
// filtered rows, and keyboard navigation. Enter or a click on an enabled
// match returns its command and closes the palette; Escape or an outside
// click reports `dismissed`. The caller owns `open`, the state, and the modal,
// and only acts on the returned command.
command_palette_draw :: proc(
	frame: ^Ui_Frame,
	state: ^Command_Palette_State,
	modal: ^Modal_State,
	items: []Command_Palette_Item,
	open: ^bool,
	options: Command_Palette_Options = {},
) -> Command_Palette_Result {
	assert(frame != nil && frame.open, "command_palette_draw: invalid frame")
	assert(state != nil && modal != nil && open != nil, "command_palette_draw: nil state")
	if !open^ {
		if modal.open do modal_close(modal)
		return {}
	}
	config := command_palette_config(frame)
	if config.screen.w <= 0 || config.screen.h <= 0 do return {}
	if !modal_open(frame, modal, COMMAND_PALETTE_MODAL_ID, config) do return {}
	title := options.title if options.title != "" else "Command palette"
	body := modal_begin(frame, modal, title, config)
	metrics := ui_frame_metrics(frame)
	pad := metrics.PADDING
	row_h := metrics.ROW_H_MD
	command_palette_keys(frame, state)
	query_rect := Rect_I32{body.x + pad, body.y, max(body.w - pad * 2, 1), row_h}
	placeholder := options.placeholder if options.placeholder != "" else "Search commands"
	submitted := text_input_at(frame, query_rect, &state.query, placeholder, true)
	matches := command_palette_filter(state, items, input_box_text(&state.query))
	result: Command_Palette_Result
	list_y := query_rect.y + row_h + metrics.CONTROL_GAP
	visible := min(len(matches) - state.window, COMMAND_PALETTE_VISIBLE_MAX)
	for offset in 0 ..< max(visible, 0) {
		position := state.window + offset
		item := items[matches[position]]
		rect := Rect_I32{query_rect.x, list_y + i32(offset) * row_h, query_rect.w, row_h}
		if command_palette_row(
			frame,
			rect,
			item,
			position == state.selected,
			position,
			len(matches),
		) {
			state.selected = position
			result.activated = item.command
		}
	}
	if len(matches) == 0 {
		note := options.empty_note if options.empty_note != "" else "No matches"
		size := metrics.FONT_SIZE_LABEL
		y := frame_text_center_y(frame, list_y, row_h, size)
		draw_text_string_frame(frame, note, query_rect.x + pad, y, size, text_ink(frame, .Muted))
	} else if submitted && !items[matches[state.selected]].disabled {
		result.activated = items[matches[state.selected]].command
	}
	modal_end(modal)
	if result.activated != action.COMMAND_ID_NONE {
		modal_close(modal, .Accepted)
	} else if !modal.open {
		result.dismissed = true
	}
	if result.activated != action.COMMAND_ID_NONE || result.dismissed {
		open^ = false
		input_box_set_text(&state.query, "")
		state.selected = 0
		state.window = 0
	}
	return result
}

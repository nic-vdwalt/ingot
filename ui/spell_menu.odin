package ui

// Right-click suggestions popup for misspelled words in the chat composer.
// Modeled on the mentions popup: a small anchored panel above the input box
// with up to SPELL_MAX_SUGGESTIONS replacements plus "Learn word" / "Ignore".
// Each Text_Input_State owns its own menu state.

import "core:strings"


SPELL_MENU_W :: 240
SPELL_MENU_ITEM_H :: 26
SPELL_MENU_PAD :: 4

Spell_Menu :: struct {
	open:        bool,
	just_opened: bool, // swallow the opening click for one frame
	sb:          ^strings.Builder,
	cursor:      ^int,
	pills:       ^[dynamic]Mention_Span,
	undo:        ^Input_Undo,
	word_start:  int,
	word_end:    int,
	word:        string, // cloned
	suggestions: []string, // cloned
	selected:    int,
	text_hash:   u64, // composer state at open; any text change closes
	text_len:    int,
	anchor_x:    i32, // pane-local x of the clicked word
	anchor_y:    i32, // top edge of the input box; menu opens above it
}

// spell_menu_active reports whether the menu is open for this builder.
spell_menu_active :: proc(menu: ^Spell_Menu, sb: ^strings.Builder) -> bool {
	assert(menu != nil, "spell_menu_active: nil menu")
	return menu.open && menu.sb == sb
}

spell_menu_open :: proc(
	menu: ^Spell_Menu,
	system: ^Spell_System,
	sb: ^strings.Builder,
	cursor: ^int,
	pills: ^[dynamic]Mention_Span,
	undo: ^Input_Undo,
	word_start, word_end: int,
	anchor_x, anchor_y: i32,
) {
	assert(menu != nil && system != nil, "spell_menu_open: nil state")
	spell_menu_close(menu)
	text := strings.to_string(sb^)
	if word_start < 0 || word_end > len(text) || word_start >= word_end do return
	menu.word = strings.clone(text[word_start:word_end])
	menu.suggestions = spell_suggest_with(system, menu.word)
	menu.sb = sb
	menu.cursor = cursor
	menu.pills = pills
	menu.undo = undo
	menu.word_start = word_start
	menu.word_end = word_end
	menu.selected = 0
	menu.text_hash = fnv1a64(text)
	menu.text_len = len(text)
	menu.anchor_x = anchor_x
	menu.anchor_y = anchor_y
	menu.open = true
	menu.just_opened = true
}

spell_menu_close :: proc(menu: ^Spell_Menu) {
	assert(menu != nil, "spell_menu_close: nil menu")
	delete(menu.word)
	for suggestion in menu.suggestions do delete(suggestion)
	delete(menu.suggestions)
	menu^ = {}
}

// spell_menu_apply performs the action for a nav index: 0..n-1 replace with
// that suggestion, n = learn, n+1 = ignore for this session.
@(private = "file")
spell_menu_apply :: proc(frame: ^Ui_Frame, menu: ^Spell_Menu, system: ^Spell_System, idx: int) {
	assert(frame != nil && menu != nil && system != nil, "spell_menu_apply: nil state")
	n := len(menu.suggestions)
	switch {
	case idx < n:
		spell_replace_word(frame, menu, menu.suggestions[idx])
	case idx == n:
		spell_learn_with(system, menu.word)
		spell_menu_close(menu)
	case:
		spell_ignore_session_with(system, menu.word)
		spell_menu_close(menu)
	}
}

// Replace the misspelled word range with `replacement`, keeping pills and the
// caret consistent and recording one undo step.
@(private = "file")
spell_replace_word :: proc(frame: ^Ui_Frame, menu: ^Spell_Menu, replacement: string) {
	assert(frame != nil && menu != nil && menu.sb != nil, "spell_replace_word: nil state")
	sb := menu.sb
	old := strings.to_string(sb^)
	ws, we := menu.word_start, menu.word_end
	if ws < 0 || we > len(old) || ws >= we {
		spell_menu_close(menu)
		return
	}
	if menu.undo != nil && menu.cursor != nil {
		pill_slice: []Mention_Span
		if menu.pills != nil do pill_slice = menu.pills[:]
		input_undo_record(
			menu.undo,
			old,
			menu.cursor^,
			pill_slice,
			.Other,
			frame_input(frame).time,
		)
	}
	new_text := strings.concatenate({old[:ws], replacement, old[we:]}, context.temp_allocator)
	strings.builder_reset(sb)
	strings.write_string(sb, new_text)
	delta := len(replacement) - (we - ws)
	if menu.pills != nil {
		for &pill in menu.pills {
			if pill.start >= we {
				pill.start += delta
				pill.end += delta
			}
		}
	}
	if menu.cursor != nil do menu.cursor^ = ws + len(replacement)
	spell_menu_close(menu)
}

Spell_Menu_Layout :: struct {
	suggestion_count: int,
	menu_x, menu_y:   i32,
	menu_w, menu_h:   i32,
	item_h, menu_pad: i32,
	separator_h:      i32,
	item_x, item_w:   i32,
	menu_rect:        Rectangle,
}

@(private)
spell_menu_place :: proc(
	anchor_x, anchor_y, input_x, input_w, menu_w, menu_h, gap: i32,
) -> (
	i32,
	i32,
) {
	x := anchor_x
	if x + menu_w > input_x + input_w do x = input_x + input_w - menu_w
	if x < input_x do x = input_x
	y := anchor_y - menu_h - gap
	if y < 0 do y = 0
	return x, y
}

@(private)
spell_menu_move_selection :: proc(selected, nav_count, delta: int) -> int {
	return (selected + nav_count + delta) % nav_count
}

@(private = "file")
spell_menu_layout :: proc(
	frame: ^Ui_Frame,
	menu: ^Spell_Menu,
	input_x, input_w: i32,
) -> Spell_Menu_Layout {
	assert(frame != nil, "spell_menu_layout: nil frame")
	assert(menu != nil, "spell_menu_layout: nil menu")
	n := len(menu.suggestions)
	rows := max(n, 1) + 2
	separator_h := ui_frame_sc(frame, 5)
	menu_w := ui_frame_sc(frame, SPELL_MENU_W)
	item_h := ui_frame_sc(frame, SPELL_MENU_ITEM_H)
	menu_pad := ui_frame_sc(frame, SPELL_MENU_PAD)
	menu_h := i32(rows) * item_h + menu_pad * 2 + separator_h
	menu_x, menu_y := spell_menu_place(
		menu.anchor_x,
		menu.anchor_y,
		input_x,
		input_w,
		menu_w,
		menu_h,
		ui_frame_sc(frame, 4),
	)
	return {
		suggestion_count = n,
		menu_x = menu_x,
		menu_y = menu_y,
		menu_w = menu_w,
		menu_h = menu_h,
		item_h = item_h,
		menu_pad = menu_pad,
		separator_h = separator_h,
		item_x = menu_x + ui_frame_sc(frame, 2),
		item_w = menu_w - ui_frame_sc(frame, 4),
		menu_rect = {f32(menu_x), f32(menu_y), f32(menu_w), f32(menu_h)},
	}
}

@(private = "file")
spell_menu_handle_keyboard :: proc(
	frame: ^Ui_Frame,
	menu: ^Spell_Menu,
	system: ^Spell_System,
	nav_count: int,
) -> bool {
	assert(frame != nil, "spell_menu_handle_keyboard: nil frame")
	assert(menu != nil, "spell_menu_handle_keyboard: nil menu")
	assert(system != nil, "spell_menu_handle_keyboard: nil system")
	if is_key_pressed(frame, .ESCAPE) {
		spell_menu_close(menu)
		return true
	}
	if is_key_pressed(frame, .UP) || is_key_pressed_repeat(frame, .UP) {
		menu.selected = spell_menu_move_selection(menu.selected, nav_count, -1)
	}
	if is_key_pressed(frame, .DOWN) || is_key_pressed_repeat(frame, .DOWN) {
		menu.selected = spell_menu_move_selection(menu.selected, nav_count, 1)
	}
	if is_key_pressed(frame, .ENTER) &&
	   !is_key_down(frame, .LEFT_SHIFT) &&
	   !is_key_down(frame, .RIGHT_SHIFT) {
		spell_menu_apply(frame, menu, system, menu.selected)
		return true
	}
	return false
}

@(private = "file")
spell_menu_handle_pointer :: proc(
	frame: ^Ui_Frame,
	menu: ^Spell_Menu,
	menu_rect: Rectangle,
) -> (
	Vector2,
	bool,
) {
	assert(frame != nil, "spell_menu_handle_pointer: nil frame")
	assert(menu != nil, "spell_menu_handle_pointer: nil menu")
	mouse := frame_to_local(frame, get_mouse_position(frame))
	pressed := is_mouse_button_pressed(frame, .LEFT) || is_mouse_button_pressed(frame, .RIGHT)
	if !menu.just_opened && pressed && !point_in_rect(mouse, menu_rect) {
		spell_menu_close(menu)
		return mouse, true
	}
	menu.just_opened = false
	return mouse, false
}

@(private = "file")
spell_menu_draw_row :: proc(
	frame: ^Ui_Frame,
	menu: ^Spell_Menu,
	origin_x, origin_y, item_x, item_y, item_w, item_h: i32,
	label: string,
	nav_index: int,
	mouse: Vector2,
	color: Color,
) -> bool {
	assert(frame != nil, "spell_menu_draw_row: nil frame")
	assert(menu != nil, "spell_menu_draw_row: nil menu")
	row_rect := Rectangle{f32(item_x), f32(item_y), f32(item_w), f32(item_h)}
	hovered := point_in_rect(mouse, row_rect)
	if hovered && mouse_moved(frame) do menu.selected = nav_index
	if menu.selected == nav_index {
		overlay_rect(
			frame,
			{f32(item_x + origin_x), f32(item_y + origin_y), f32(item_w), f32(item_h)},
			ui_frame_theme(frame).bg_active,
		)
	}
	if hovered do request_cursor(frame, .POINTING_HAND)
	font_size := text_role_size(frame, .Body)
	text := truncate_to_width_frame(frame, label, item_w - ui_frame_sc(frame, 16), font_size)
	overlay_text(
		frame,
		text,
		item_x + origin_x + ui_frame_sc(frame, 8),
		item_y + origin_y + (item_h - font_size) / 2,
		font_size,
		color,
	)
	return hovered && is_mouse_button_released(frame, .LEFT)
}

@(private = "file")
spell_menu_draw_suggestions :: proc(
	frame: ^Ui_Frame,
	menu: ^Spell_Menu,
	layout: ^Spell_Menu_Layout,
	origin_x, origin_y: i32,
	mouse: Vector2,
) -> (
	int,
	i32,
) {
	assert(frame != nil, "spell_menu_draw_suggestions: nil frame")
	assert(menu != nil, "spell_menu_draw_suggestions: nil menu")
	assert(layout != nil, "spell_menu_draw_suggestions: nil layout")
	item_y := layout.menu_y + layout.menu_pad
	apply_index := -1
	if layout.suggestion_count == 0 {
		font_size := text_role_size(frame, .Body)
		text := truncate_to_width_frame(
			frame,
			"No suggestions",
			layout.item_w - ui_frame_sc(frame, 16),
			font_size,
		)
		overlay_text(
			frame,
			text,
			layout.item_x + origin_x + ui_frame_sc(frame, 8),
			item_y + origin_y + (layout.item_h - font_size) / 2,
			font_size,
			text_ink(frame, .Disabled),
		)
		return -1, item_y + layout.item_h
	}
	for suggestion, index in menu.suggestions {
		if spell_menu_draw_row(
			frame,
			menu,
			origin_x,
			origin_y,
			layout.item_x,
			item_y,
			layout.item_w,
			layout.item_h,
			suggestion,
			index,
			mouse,
			ui_frame_theme(frame).fg_primary,
		) {
			apply_index = index
		}
		item_y += layout.item_h
	}
	return apply_index, item_y
}

@(private = "file")
spell_menu_draw_actions :: proc(
	frame: ^Ui_Frame,
	menu: ^Spell_Menu,
	layout: ^Spell_Menu_Layout,
	origin_x, origin_y, item_y: i32,
	mouse: Vector2,
) -> int {
	assert(frame != nil, "spell_menu_draw_actions: nil frame")
	assert(menu != nil, "spell_menu_draw_actions: nil menu")
	assert(layout != nil, "spell_menu_draw_actions: nil layout")
	style := ui_frame_theme(frame)
	current_y := item_y
	overlay_rect(
		frame,
		{
			f32(layout.menu_x + origin_x + ui_frame_sc(frame, 6)),
			f32(current_y + origin_y + layout.separator_h / 2),
			f32(layout.menu_w - ui_frame_sc(frame, 12)),
			1,
		},
		style.border_color,
	)
	current_y += layout.separator_h
	apply_index := -1
	learn := strings.concatenate({"Learn \"", menu.word, "\""}, context.temp_allocator)
	if spell_menu_draw_row(
		frame,
		menu,
		origin_x,
		origin_y,
		layout.item_x,
		current_y,
		layout.item_w,
		layout.item_h,
		learn,
		layout.suggestion_count,
		mouse,
		style.fg_secondary,
	) {
		apply_index = layout.suggestion_count
	}
	current_y += layout.item_h
	if spell_menu_draw_row(
		frame,
		menu,
		origin_x,
		origin_y,
		layout.item_x,
		current_y,
		layout.item_w,
		layout.item_h,
		"Ignore",
		layout.suggestion_count + 1,
		mouse,
		style.fg_secondary,
	) {
		apply_index = layout.suggestion_count + 1
	}
	return apply_index
}

@(private)
spell_menu_screen_rect :: proc(frame: ^Ui_Frame, layout: ^Spell_Menu_Layout) -> Rectangle {
	assert(frame != nil, "spell_menu_screen_rect: nil frame")
	assert(layout != nil, "spell_menu_screen_rect: nil layout")
	return frame_rect_to_screen(
		frame,
		{f32(layout.menu_x), f32(layout.menu_y), f32(layout.menu_w), f32(layout.menu_h)},
	)
}

@(private = "file")
spell_menu_draw_overlay :: proc(
	frame: ^Ui_Frame,
	menu: ^Spell_Menu,
	layout: ^Spell_Menu_Layout,
	mouse: Vector2,
) -> int {
	assert(frame != nil, "spell_menu_draw_overlay: nil frame")
	assert(menu != nil, "spell_menu_draw_overlay: nil menu")
	assert(layout != nil, "spell_menu_draw_overlay: nil layout")
	style := ui_frame_theme(frame)
	origin := frame_pane_origin(frame)
	origin_x, origin_y := i32(origin.x), i32(origin.y)
	screen_rect := spell_menu_screen_rect(frame, layout)
	overlay_begin(frame, screen_rect, claim_input = true)
	overlay_rect(frame, screen_rect, style.bg_popup)
	overlay_rect_lines(frame, screen_rect, ui_frame_scf(frame, 1), style.border_color)
	apply_index, item_y := spell_menu_draw_suggestions(
		frame,
		menu,
		layout,
		origin_x,
		origin_y,
		mouse,
	)
	action_index := spell_menu_draw_actions(frame, menu, layout, origin_x, origin_y, item_y, mouse)
	if action_index >= 0 do apply_index = action_index
	overlay_end(frame)
	return apply_index
}

// draw_spell_menu renders and drives the popup. Called from text_input while
// its scissor may still be active: the panel's draws are recorded on the
// overlay layer, so they replay above all main content at overlay_flush time
// (and the menu rect is claimed with the input router, so clicks on the menu
// never leak through to the widgets underneath). Input coords are pane-local,
// matching the composer's drawing space; recorded draw coords are shifted to
// screen space because the overlay replays after pane translation is popped.
draw_spell_menu :: proc(
	frame: ^Ui_Frame,
	menu: ^Spell_Menu,
	system: ^Spell_System,
	input_x, input_y, input_w: i32,
) {
	assert(menu != nil && system != nil, "draw_spell_menu: nil state")
	if !menu.open do return
	_ = input_y
	text := strings.to_string(menu.sb^)
	if fnv1a64(text) != menu.text_hash || len(text) != menu.text_len {
		spell_menu_close(menu)
		return
	}
	layout := spell_menu_layout(frame, menu, input_x, input_w)
	if spell_menu_handle_keyboard(frame, menu, system, layout.suggestion_count + 2) do return
	mouse, closed := spell_menu_handle_pointer(frame, menu, layout.menu_rect)
	if closed do return
	apply_index := spell_menu_draw_overlay(frame, menu, &layout, mouse)
	if apply_index >= 0 do spell_menu_apply(frame, menu, system, apply_index)
}

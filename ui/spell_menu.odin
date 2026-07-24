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
spell_menu_apply :: proc(menu: ^Spell_Menu, system: ^Spell_System, idx: int) {
	assert(menu != nil && system != nil, "spell_menu_apply: nil state")
	n := len(menu.suggestions)
	switch {
	case idx < n:
		spell_replace_word(menu, menu.suggestions[idx])
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
spell_replace_word :: proc(menu: ^Spell_Menu, replacement: string) {
	assert(menu != nil && menu.sb != nil, "spell_replace_word: nil state")
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

	// Any composer text change since open (typing, undo, paste) closes it.
	text := strings.to_string(menu.sb^)
	if fnv1a64(text) != menu.text_hash || len(text) != menu.text_len {
		spell_menu_close(menu)
		return
	}

	style := ui_frame_theme(frame)
	metrics := ui_frame_metrics(frame)
	n := len(menu.suggestions)
	rows := max(n, 1) + 2 // suggestions (or "No suggestions") + Learn + Ignore
	sep_h := ui_frame_sc(frame, 5)
	menu_w := ui_frame_sc(frame, SPELL_MENU_W)
	item_h := ui_frame_sc(frame, SPELL_MENU_ITEM_H)
	menu_pad := ui_frame_sc(frame, SPELL_MENU_PAD)
	menu_h := i32(rows) * item_h + menu_pad * 2 + sep_h

	mx := menu.anchor_x
	if mx + menu_w > input_x + input_w do mx = input_x + input_w - menu_w
	if mx < input_x do mx = input_x
	my := menu.anchor_y - menu_h - ui_frame_sc(frame, 4)
	if my < 0 do my = 0

	nav_count := n + 2

	// Keyboard: Up/Down navigate, Enter applies, Escape closes.
	if is_key_pressed(frame, .ESCAPE) {
		spell_menu_close(menu)
		return
	}
	if is_key_pressed(frame, .UP) || is_key_pressed_repeat(frame, .UP) {
		menu.selected = (menu.selected + nav_count - 1) % nav_count
	}
	if is_key_pressed(frame, .DOWN) || is_key_pressed_repeat(frame, .DOWN) {
		menu.selected = (menu.selected + 1) % nav_count
	}
	if is_key_pressed(frame, .ENTER) &&
	   !is_key_down(frame, .LEFT_SHIFT) &&
	   !is_key_down(frame, .RIGHT_SHIFT) {
		spell_menu_apply(menu, system, menu.selected)
		return
	}

	mouse := get_mouse_position(frame)
	mouse = frame_to_local(frame, mouse)
	menu_rect := Rectangle{f32(mx), f32(my), f32(menu_w), f32(menu_h)}

	// Click-away closes (the opening right-click is swallowed for one frame).
	if !menu.just_opened &&
	   (is_mouse_button_pressed(frame, .LEFT) || is_mouse_button_pressed(frame, .RIGHT)) &&
	   !point_in_rect(mouse, menu_rect) {
		spell_menu_close(menu)
		return
	}
	menu.just_opened = false

	// Record all panel draws on the overlay layer in screen space; the group
	// rect also claims the covered area with the input router.
	origin := frame_pane_origin(frame)
	ox := i32(origin.x)
	screen_rect := Rectangle{f32(mx + ox), f32(my), f32(menu_w), f32(menu_h)}
	overlay_begin(frame, screen_rect, claim_input = true)
	overlay_rect(frame, screen_rect, style.bg_popup)
	overlay_rect_lines(frame, screen_rect, ui_frame_scf(frame, 1), style.border_color)

	item_x := mx + ui_frame_sc(frame, 2)
	item_w := menu_w - ui_frame_sc(frame, 4)
	item_y := my + menu_pad

	draw_row :: proc(
		frame: ^Ui_Frame,
		menu: ^Spell_Menu,
		ox, item_x, item_y, item_w, item_h: i32,
		label: string,
		nav_idx: int,
		mouse: Vector2,
		color: Color,
	) -> bool {
		assert(menu != nil, "draw_spell_menu row: nil menu")
		row_rect := Rectangle{f32(item_x), f32(item_y), f32(item_w), f32(item_h)}
		hovered := point_in_rect(mouse, row_rect)
		if hovered && mouse_moved() do menu.selected = nav_idx
		if menu.selected == nav_idx {
			overlay_rect(
				frame,
				{f32(item_x + ox), f32(item_y), f32(item_w), f32(item_h)},
				ui_frame_theme(frame).bg_active,
			)
		}
		if hovered do request_cursor(frame, .POINTING_HAND)
		font_size := ui_frame_metrics(frame).FONT_SIZE_BODY
		txt := truncate_to_width_frame(frame, label, item_w - ui_frame_sc(frame, 16), font_size)
		overlay_text(
			frame,
			txt,
			item_x + ox + ui_frame_sc(frame, 8),
			item_y + (item_h - font_size) / 2,
			font_size,
			color,
		)
		return hovered && is_mouse_button_released(frame, .LEFT)
	}

	// Collect the clicked action and apply it only after the overlay group is
	// closed, so every path leaves the recorder balanced.
	apply_idx := -1
	if n == 0 {
		txt := truncate_to_width_frame(
			frame,
			"No suggestions",
			item_w - ui_frame_sc(frame, 16),
			metrics.FONT_SIZE_BODY,
		)
		overlay_text(
			frame,
			txt,
			item_x + ox + ui_frame_sc(frame, 8),
			item_y + (item_h - metrics.FONT_SIZE_BODY) / 2,
			metrics.FONT_SIZE_BODY,
			style.fg_disabled,
		)
		item_y += item_h
	} else {
		for suggestion, index in menu.suggestions {
			if draw_row(
				frame,
				menu,
				ox,
				item_x,
				item_y,
				item_w,
				item_h,
				suggestion,
				index,
				mouse,
				style.fg_primary,
			) {
				apply_idx = index
			}
			item_y += item_h
		}
	}

	// Separator.
	overlay_rect(
		frame,
		{
			f32(mx + ox + ui_frame_sc(frame, 6)),
			f32(item_y + sep_h / 2),
			f32(menu_w - ui_frame_sc(frame, 12)),
			1,
		},
		style.border_color,
	)
	item_y += sep_h

	learn_label := strings.concatenate({"Learn \"", menu.word, "\""}, context.temp_allocator)
	if draw_row(
		frame,
		menu,
		ox,
		item_x,
		item_y,
		item_w,
		item_h,
		learn_label,
		n,
		mouse,
		style.fg_secondary,
	) {
		apply_idx = n
	}
	item_y += item_h

	if draw_row(
		frame,
		menu,
		ox,
		item_x,
		item_y,
		item_w,
		item_h,
		"Ignore",
		n + 1,
		mouse,
		style.fg_secondary,
	) {
		apply_idx = n + 1
	}
	overlay_end(frame)

	if apply_idx >= 0 {
		spell_menu_apply(menu, system, apply_idx)
	}
}

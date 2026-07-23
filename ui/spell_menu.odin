package ui

// Right-click suggestions popup for misspelled words in the chat composer.
// Modeled on the mentions popup: a small anchored panel above the input box
// with up to SPELL_MAX_SUGGESTIONS replacements plus "Learn word" / "Ignore".
// Module-level state, like input_sel: only one composer is focused at a time.

import "core:strings"
import rl "ingot:gfx"

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

spell_menu: Spell_Menu

// spell_menu_active reports whether the menu is open for this builder.
spell_menu_active :: proc(sb: ^strings.Builder) -> bool {
	return spell_menu.open && spell_menu.sb == sb
}

spell_menu_open :: proc(
	sb: ^strings.Builder,
	cursor: ^int,
	pills: ^[dynamic]Mention_Span,
	undo: ^Input_Undo,
	word_start, word_end: int,
	anchor_x, anchor_y: i32,
) {
	spell_menu_close()
	text := strings.to_string(sb^)
	if word_start < 0 || word_end > len(text) || word_start >= word_end do return
	spell_menu.word = strings.clone(text[word_start:word_end])
	spell_menu.suggestions = spell_suggest(spell_menu.word)
	spell_menu.sb = sb
	spell_menu.cursor = cursor
	spell_menu.pills = pills
	spell_menu.undo = undo
	spell_menu.word_start = word_start
	spell_menu.word_end = word_end
	spell_menu.selected = 0
	spell_menu.text_hash = fnv1a64(text)
	spell_menu.text_len = len(text)
	spell_menu.anchor_x = anchor_x
	spell_menu.anchor_y = anchor_y
	spell_menu.open = true
	spell_menu.just_opened = true
}

spell_menu_close :: proc() {
	delete(spell_menu.word)
	for s in spell_menu.suggestions do delete(s)
	delete(spell_menu.suggestions)
	spell_menu = {}
}

// spell_menu_apply performs the action for a nav index: 0..n-1 replace with
// that suggestion, n = learn, n+1 = ignore for this session.
@(private = "file")
spell_menu_apply :: proc(idx: int) {
	n := len(spell_menu.suggestions)
	switch {
	case idx < n:
		spell_replace_word(spell_menu.suggestions[idx])
	case idx == n:
		spell_learn(spell_menu.word)
		spellcheck_invalidate()
		spell_menu_close()
	case:
		spell_ignore_session(spell_menu.word)
		spellcheck_invalidate()
		spell_menu_close()
	}
}

// Replace the misspelled word range with `replacement`, keeping pills and the
// caret consistent and recording one undo step.
@(private = "file")
spell_replace_word :: proc(replacement: string) {
	sb := spell_menu.sb
	old := strings.to_string(sb^)
	ws, we := spell_menu.word_start, spell_menu.word_end
	if ws < 0 || we > len(old) || ws >= we {
		spell_menu_close()
		return
	}
	if spell_menu.undo != nil && spell_menu.cursor != nil {
		pill_slice: []Mention_Span
		if spell_menu.pills != nil do pill_slice = spell_menu.pills[:]
		input_undo_record(
			spell_menu.undo,
			old,
			spell_menu.cursor^,
			pill_slice,
			.Other,
			rl.GetTime(),
		)
	}
	new_text := strings.concatenate({old[:ws], replacement, old[we:]}, context.temp_allocator)
	strings.builder_reset(sb)
	strings.write_string(sb, new_text)
	delta := len(replacement) - (we - ws)
	if spell_menu.pills != nil {
		for &p in spell_menu.pills {
			if p.start >= we {
				p.start += delta
				p.end += delta
			}
		}
	}
	if spell_menu.cursor != nil do spell_menu.cursor^ = ws + len(replacement)
	spellcheck_invalidate()
	spell_menu_close()
}

// draw_spell_menu renders and drives the popup. Called from text_input while
// its scissor may still be active: the panel's draws are recorded on the
// overlay layer, so they replay above all main content at overlay_flush time
// (and the menu rect is claimed with the input router, so clicks on the menu
// never leak through to the widgets underneath). Input coords are pane-local,
// matching the composer's drawing space; recorded draw coords are shifted to
// screen space because the overlay replays after pane translation is popped.
draw_spell_menu :: proc(input_x, input_y, input_w: i32) {
	if !spell_menu.open do return

	// Any composer text change since open (typing, undo, paste) closes it.
	text := strings.to_string(spell_menu.sb^)
	if fnv1a64(text) != spell_menu.text_hash || len(text) != spell_menu.text_len {
		spell_menu_close()
		return
	}

	n := len(spell_menu.suggestions)
	rows := max(n, 1) + 2 // suggestions (or "No suggestions") + Learn + Ignore
	sep_h: i32 = 5
	menu_w: i32 = SPELL_MENU_W
	menu_h := i32(rows) * SPELL_MENU_ITEM_H + SPELL_MENU_PAD * 2 + sep_h

	mx := spell_menu.anchor_x
	if mx + menu_w > input_x + input_w do mx = input_x + input_w - menu_w
	if mx < input_x do mx = input_x
	my := spell_menu.anchor_y - menu_h - 4
	if my < 0 do my = 0

	nav_count := n + 2

	// Keyboard: Up/Down navigate, Enter applies, Escape closes.
	if rl.IsKeyPressed(.ESCAPE) {
		spell_menu_close()
		return
	}
	if rl.IsKeyPressed(.UP) || rl.IsKeyPressedRepeat(.UP) {
		spell_menu.selected = (spell_menu.selected + nav_count - 1) % nav_count
	}
	if rl.IsKeyPressed(.DOWN) || rl.IsKeyPressedRepeat(.DOWN) {
		spell_menu.selected = (spell_menu.selected + 1) % nav_count
	}
	if rl.IsKeyPressed(.ENTER) && !rl.IsKeyDown(.LEFT_SHIFT) && !rl.IsKeyDown(.RIGHT_SHIFT) {
		spell_menu_apply(spell_menu.selected)
		return
	}

	mouse := rl.GetMousePosition()
	mouse.x -= f32(pane_origin_x)
	menu_rect := rl.Rectangle{f32(mx), f32(my), f32(menu_w), f32(menu_h)}

	// Click-away closes (the opening right-click is swallowed for one frame).
	if !spell_menu.just_opened &&
	   (rl.IsMouseButtonPressed(.LEFT) || rl.IsMouseButtonPressed(.RIGHT)) &&
	   !rl.CheckCollisionPointRec(mouse, menu_rect) {
		spell_menu_close()
		return
	}
	spell_menu.just_opened = false

	// Record all panel draws on the overlay layer in screen space; the group
	// rect also claims the covered area with the input router.
	ox := pane_origin_x
	screen_rect := rl.Rectangle{f32(mx + ox), f32(my), f32(menu_w), f32(menu_h)}
	overlay_begin(screen_rect, claim_input = true)
	overlay_rect(screen_rect, theme.bg_popup)
	overlay_rect_lines(screen_rect, 1, theme.border_color)

	item_x := mx + 2
	item_w := menu_w - 4
	item_y := my + SPELL_MENU_PAD

	draw_row :: proc(
		ox, item_x, item_y, item_w: i32,
		label: string,
		nav_idx: int,
		mouse: rl.Vector2,
		color: rl.Color,
	) -> bool {
		row_rect := rl.Rectangle{f32(item_x), f32(item_y), f32(item_w), f32(SPELL_MENU_ITEM_H)}
		hovered := rl.CheckCollisionPointRec(mouse, row_rect)
		if hovered && mouse_moved() do spell_menu.selected = nav_idx
		if spell_menu.selected == nav_idx {
			overlay_rect(
				{f32(item_x + ox), f32(item_y), f32(item_w), f32(SPELL_MENU_ITEM_H)},
				theme.bg_active,
			)
		}
		if hovered do request_cursor(.POINTING_HAND)
		txt := truncate_to_width(label, item_w - 16, FONT_SIZE)
		overlay_text(
			txt,
			item_x + ox + 8,
			item_y + (SPELL_MENU_ITEM_H - FONT_SIZE) / 2,
			FONT_SIZE,
			color,
		)
		return hovered && rl.IsMouseButtonReleased(.LEFT)
	}

	// Collect the clicked action and apply it only after the overlay group is
	// closed, so every path leaves the recorder balanced.
	apply_idx := -1
	if n == 0 {
		txt := truncate_to_width("No suggestions", item_w - 16, FONT_SIZE)
		overlay_text(
			txt,
			item_x + ox + 8,
			item_y + (SPELL_MENU_ITEM_H - FONT_SIZE) / 2,
			FONT_SIZE,
			theme.fg_disabled,
		)
		item_y += SPELL_MENU_ITEM_H
	} else {
		for s, i in spell_menu.suggestions {
			if draw_row(ox, item_x, item_y, item_w, s, i, mouse, theme.fg_primary) {
				apply_idx = i
			}
			item_y += SPELL_MENU_ITEM_H
		}
	}

	// Separator.
	overlay_rect(
		{f32(mx + ox + 6), f32(item_y + sep_h / 2), f32(menu_w - 12), 1},
		theme.border_color,
	)
	item_y += sep_h

	learn_label := strings.concatenate({"Learn \"", spell_menu.word, "\""}, context.temp_allocator)
	if draw_row(ox, item_x, item_y, item_w, learn_label, n, mouse, theme.fg_secondary) {
		apply_idx = n
	}
	item_y += SPELL_MENU_ITEM_H

	if draw_row(ox, item_x, item_y, item_w, "Ignore", n + 1, mouse, theme.fg_secondary) {
		apply_idx = n + 1
	}
	overlay_end()

	if apply_idx >= 0 {
		spell_menu_apply(apply_idx)
	}
}

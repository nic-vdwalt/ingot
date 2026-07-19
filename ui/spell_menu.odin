package ui

// Right-click suggestions popup for misspelled words in the chat composer.
// Modeled on the mentions popup: a small anchored panel above the input box
// with up to SPELL_MAX_SUGGESTIONS replacements plus "Learn word" / "Ignore".
// Module-level state, like input_sel: only one composer is focused at a time.

import "core:strings"
import rl "vendor:raylib"

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
		input_undo_record(spell_menu.undo, old, spell_menu.cursor^, pill_slice, .Other, rl.GetTime())
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

// draw_spell_menu renders and drives the popup. Called from text_input after
// its scissor ends so the panel draws unclipped above the input box. Input
// coords are pane-local, matching the composer's drawing space.
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
	menu_h := i32(rows)*SPELL_MENU_ITEM_H + SPELL_MENU_PAD*2 + sep_h

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

	rl.DrawRectangleRec(menu_rect, BG_POPUP)
	rl.DrawRectangleLinesEx(menu_rect, 1, BORDER_COLOR)

	item_x := mx + 2
	item_w := menu_w - 4
	item_y := my + SPELL_MENU_PAD

	draw_row :: proc(item_x, item_y, item_w: i32, label: string, nav_idx: int, mouse: rl.Vector2, color: rl.Color) -> bool {
		row_rect := rl.Rectangle{f32(item_x), f32(item_y), f32(item_w), f32(SPELL_MENU_ITEM_H)}
		hovered := rl.CheckCollisionPointRec(mouse, row_rect)
		if hovered && mouse_moved() do spell_menu.selected = nav_idx
		if spell_menu.selected == nav_idx {
			rl.DrawRectangleRec(row_rect, BG_ACTIVE)
		}
		if hovered do request_cursor(.POINTING_HAND)
		draw_text_truncated(label, item_x + 8, item_y + (SPELL_MENU_ITEM_H - FONT_SIZE) / 2, item_w - 16, FONT_SIZE, color)
		return hovered && rl.IsMouseButtonReleased(.LEFT)
	}

	if n == 0 {
		draw_text_truncated("No suggestions", item_x + 8, item_y + (SPELL_MENU_ITEM_H - FONT_SIZE) / 2, item_w - 16, FONT_SIZE, FG_DISABLED)
		item_y += SPELL_MENU_ITEM_H
	} else {
		for s, i in spell_menu.suggestions {
			if draw_row(item_x, item_y, item_w, s, i, mouse, FG_PRIMARY) {
				spell_menu_apply(i)
				return
			}
			item_y += SPELL_MENU_ITEM_H
		}
	}

	// Separator.
	rl.DrawRectangle(mx + 6, item_y + sep_h/2, menu_w - 12, 1, BORDER_COLOR)
	item_y += sep_h

	learn_label := strings.concatenate({"Learn \"", spell_menu.word, "\""}, context.temp_allocator)
	if draw_row(item_x, item_y, item_w, learn_label, n, mouse, FG_SECONDARY) {
		spell_menu_apply(n)
		return
	}
	item_y += SPELL_MENU_ITEM_H

	if draw_row(item_x, item_y, item_w, "Ignore", n + 1, mouse, FG_SECONDARY) {
		spell_menu_apply(n + 1)
		return
	}
}

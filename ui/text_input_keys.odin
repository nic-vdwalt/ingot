// Text input: keyboard pipeline - selection shortcuts, insertion, deletion,
// enter handling, and logical/visual caret navigation.
package ui

import "core:strings"
import "core:unicode/utf8"

// ti_keys_select handles selection ownership upkeep plus Cmd/Ctrl+A/C/X and
// undo/redo shortcuts.
@(private = "file")
ti_keys_select :: proc(ctx: ^TI_Ctx, mods, shift: bool) {
	assert(ctx.sb != nil, "ti_keys_select: nil builder")
	assert(ctx.sel != nil, "ti_keys_select: nil selection")
	sb := ctx.sb
	sel := ctx.sel
	// A selection owned by a different (now unfocused / possibly dead)
	// builder is stale - drop it so its pointer is never trusted.
	if sel.active && sel.sb != sb {
		sel_reset(sel)
	}
	// Clamp against external buffer rewrites (mention completion).
	if ti_sel_owner(ctx) {
		s := strings.to_string(sb^)
		sel.anchor = caret_clamp(s, sel.anchor)
		sel.extent = caret_clamp(s, sel.extent)
		sel.active = sel.anchor != sel.extent
	}
	// Keep the caret within bounds (the buffer may have been rewritten by
	// command/mention completion since the last frame).
	if ctx.caret {
		ctx.cursor^ = caret_clamp(strings.to_string(sb^), ctx.cursor^)
	}
	// Non-caret inputs: clicking inside clears the selection (caret inputs
	// handle mouse press/drag in the render section).
	if !ctx.caret && ti_sel_owner(ctx) && is_mouse_button_pressed(ctx.frame, .LEFT) {
		screen_mouse := get_mouse_position(ctx.frame)
		if point_in_rect(screen_mouse, ctx.rect) && !route_occluded(ctx.frame, screen_mouse) {
			sel_reset(sel)
		}
	}
	// Select all (Cmd/Ctrl+A).
	if mods && is_key_pressed(ctx.frame, .A) {
		if strings.builder_len(sb^) > 0 {
			sel_set(sel, sb, 0, strings.builder_len(sb^))
			if ctx.caret do ctx.cursor^ = strings.builder_len(sb^)
		}
	}
	// Copy (Cmd/Ctrl+C) - copies the selected range. Masked (password)
	// inputs never export plaintext, matching the semantic layer's masking.
	if mods && is_key_pressed(ctx.frame, .C) && ti_sel_owner(ctx) && !ctx.masked {
		s := strings.to_string(sb^)
		lo, hi := sel_range(sel)
		if lo < hi && hi <= len(s) {
			platform_set_clipboard(&ctx.frame.output.platform, s[lo:hi])
		}
	}
	// Cut (Cmd/Ctrl+X) - copies the selected range then deletes it. A masked
	// input still deletes, but never populates the clipboard.
	if mods && is_key_pressed(ctx.frame, .X) && ti_sel_owner(ctx) {
		s := strings.to_string(sb^)
		lo, hi := sel_range(sel)
		if lo < hi && hi <= len(s) {
			if !ctx.masked {
				platform_set_clipboard(&ctx.frame.output.platform, s[lo:hi])
			}
			undo_record(ctx.frame, ctx.undo, sb, ctx.cursor, ctx.pills, .Other)
			nc := selection_delete(sel, sb, ctx.pills)
			if ctx.caret do ctx.cursor^ = nc
		}
	}
	// Undo / Redo (Cmd/Ctrl+Z, +Shift for redo).
	if mods &&
	   ctx.undo != nil &&
	   (is_key_pressed(ctx.frame, .Z) || is_key_pressed_repeat(ctx.frame, .Z)) {
		undo_apply(sel, ctx.undo, sb, ctx.cursor, ctx.pills, redo = shift)
	}
}

// ti_budget_len is the builder length that survives the pending edit: an
// owned selection is deleted before an insert, so its bytes don't count
// against the byte budget.
@(private = "file")
ti_budget_len :: proc(ctx: ^TI_Ctx) -> int {
	assert(ctx.sb != nil, "ti_budget_len: nil builder")
	length := strings.builder_len(ctx.sb^)
	if ti_sel_owner(ctx) {
		lo, hi := sel_range(ctx.sel)
		length -= hi - lo
	}
	assert(length >= 0, "ti_budget_len: negative budget")
	return length
}

// ti_insert_text records one undo step, replaces any owned selection with
// `insert`, and keeps mention pills in step. One shared helper because four
// call sites used to duplicate this block and drift apart (the paste
// byte-budget bug). Callers enforce the byte budget before calling.
@(private = "file")
ti_insert_text :: proc(ctx: ^TI_Ctx, insert: string, kind: Input_Edit_Kind) {
	assert(ctx.sb != nil, "ti_insert_text: nil builder")
	assert(len(insert) > 0, "ti_insert_text: empty insert")
	sb := ctx.sb
	undo_record(ctx.frame, ctx.undo, sb, ctx.cursor, ctx.pills, ti_sel_owner(ctx) ? .Other : kind)
	if ti_sel_owner(ctx) {
		nc := selection_delete(ctx.sel, sb, ctx.pills)
		if ctx.caret do ctx.cursor^ = nc
	}
	if ctx.caret {
		before := ctx.cursor^
		ctx.cursor^ = caret_insert(sb, ctx.cursor^, insert)
		if ctx.pills != nil do pills_shift_after_insert(ctx.pills, before, ctx.cursor^ - before)
	} else {
		strings.write_string(sb, insert)
	}
}

// ti_keys_insert handles typed characters and paste.
@(private = "file")
ti_keys_insert :: proc(ctx: ^TI_Ctx, mods: bool) {
	assert(ctx.sb != nil, "ti_keys_insert: nil builder")
	assert(ctx.sel != nil, "ti_keys_insert: nil selection")
	sb := ctx.sb
	// Handle character input. Ignore characters while a modifier is held so
	// shortcuts (Cmd+A/C/X/V/Z) don't insert their letters.
	for index in 0 ..< frame_input(ctx.frame).character_count {
		ch := rune(frame_input(ctx.frame).characters[index])
		if mods || (ctx.single_line && ch == '\n') do continue
		if ctx.filter != nil && !ctx.filter(ch) do continue
		buf, rune_size := utf8.encode_rune(ch)
		if ti_budget_len(ctx) + rune_size > ctx.max_bytes do continue
		// Typing over a selection replaces it (one undo step).
		ti_insert_text(ctx, string(buf[:rune_size]), .Insert)
	}
	// Handle paste (Cmd+V / Ctrl+V).
	if is_key_pressed(ctx.frame, .V) && mods {
		clip_str := input_clipboard(frame_input(ctx.frame))
		// Pasting over a selection deletes it first, so the byte budget is
		// measured against the post-delete length - otherwise pasting over
		// select-all in a nearly full buffer is wrongly truncated.
		base_len := ti_budget_len(ctx)
		paste := strings.builder_make(context.temp_allocator)
		for ch in clip_str {
			if ctx.single_line && ch == '\n' do continue
			// Strip carriage returns so CRLF clipboard text pastes as LF.
			if ch == '\r' do continue
			if ctx.filter != nil && !ctx.filter(ch) do continue
			_, rune_size := utf8.encode_rune(ch)
			if base_len + strings.builder_len(paste) + rune_size > ctx.max_bytes do break
			strings.write_rune(&paste, ch)
		}
		paste_text := strings.to_string(paste)
		if len(paste_text) > 0 {
			ti_insert_text(ctx, paste_text, .Other)
			assert(strings.builder_len(sb^) <= ctx.max_bytes, "ti_keys_insert: paste over budget")
		}
	}
}

// ti_delete_range deletes bytes [lo,hi) from the builder without needing an
// active selection, mirroring selection_delete's pill handling: pills that
// intersect the range are dropped (they stop being atomic tokens) and later
// pills shift left. Returns the new caret (lo). Callers record undo first
// and guarantee a non-empty in-bounds range.
@(private = "file")
ti_delete_range :: proc(ctx: ^TI_Ctx, lo, hi: int) -> int {
	assert(ctx.sb != nil, "ti_delete_range: nil builder")
	old := strings.to_string(ctx.sb^)
	assert(0 <= lo && lo < hi && hi <= len(old), "ti_delete_range: invalid range")
	if ctx.pills != nil do pills_shift_after_delete(ctx.pills, lo, hi - lo)
	combined := strings.concatenate({old[:lo], old[hi:]}, context.temp_allocator)
	strings.builder_reset(ctx.sb)
	strings.write_string(ctx.sb, combined)
	return lo
}

// ti_backspace_target returns the deletion start for a backspace with the
// given modifiers: word start for Alt (composer muscle memory), line start
// for Cmd/Ctrl (macOS delete-to-line-start), else one rune.
@(private = "file")
ti_backspace_target :: proc(s: string, pos: int, word, mods: bool) -> int {
	assert(pos > 0 && pos <= len(s), "ti_backspace_target: caret out of range")
	target := caret_prev_rune(s, pos)
	if word do target = caret_word_left(s, pos)
	if mods do target = caret_line_start(s, pos)
	assert(target >= 0 && target <= pos, "ti_backspace_target: target past caret")
	return target
}

// ti_keys_delete handles backspace (rune, Alt-word, Cmd-line, atomic pill)
// variants. Snapshots are only recorded when something will actually change:
// a snapshot for a no-op delete makes one Cmd+Z appear to do nothing.
@(private = "file")
ti_keys_delete :: proc(ctx: ^TI_Ctx, mods: bool) {
	assert(ctx.sb != nil, "ti_keys_delete: nil builder")
	assert(ctx.sel != nil, "ti_keys_delete: nil selection")
	sb := ctx.sb
	word := is_key_down(ctx.frame, .LEFT_ALT) || is_key_down(ctx.frame, .RIGHT_ALT)
	if is_key_pressed(ctx.frame, .BACKSPACE) || is_key_pressed_repeat(ctx.frame, .BACKSPACE) {
		if ti_sel_owner(ctx) {
			// Delete the selected range.
			undo_record(ctx.frame, ctx.undo, sb, ctx.cursor, ctx.pills, .Other)
			nc := selection_delete(ctx.sel, sb, ctx.pills)
			if ctx.caret do ctx.cursor^ = nc
		} else if ctx.caret {
			if ctx.cursor^ > 0 {
				if word || mods {
					s := strings.to_string(sb^)
					target := ti_backspace_target(s, ctx.cursor^, word, mods)
					// Cmd+Backspace at column 0 targets the caret itself -
					// nothing to delete, so no snapshot either.
					if target < ctx.cursor^ {
						undo_record(ctx.frame, ctx.undo, sb, ctx.cursor, ctx.pills, .Delete)
						ctx.cursor^ = ti_delete_range(ctx, target, ctx.cursor^)
					}
				} else {
					undo_record(ctx.frame, ctx.undo, sb, ctx.cursor, ctx.pills, .Delete)
					atomic := false
					if ctx.pills != nil {
						if idx, ok := pill_ending_at(ctx.pills, ctx.cursor^); ok {
							// Atomic: delete the whole pill in one keystroke.
							ctx.cursor^ = pill_delete_atomic(sb, ctx.pills, idx)
							atomic = true
						}
					}
					if !atomic {
						// Delete one grapheme cluster (whole emoji/combining
						// pair); masked inputs stay per-rune to match their
						// one-bullet-per-rune display.
						s := strings.to_string(sb^)
						target :=
							ctx.masked \
							? caret_prev_rune(s, ctx.cursor^) \
							: caret_prev_grapheme(s, ctx.cursor^)
						ctx.cursor^ = ti_delete_range(ctx, target, ctx.cursor^)
					}
				}
			}
		} else {
			s := strings.to_string(sb^)
			if len(s) > 0 {
				undo_record(ctx.frame, ctx.undo, sb, ctx.cursor, ctx.pills, .Delete)
				// Remove the last whole grapheme cluster, not the last byte.
				keep := ctx.masked ? caret_prev_rune(s, len(s)) : caret_prev_grapheme(s, len(s))
				strings.builder_reset(sb)
				strings.write_string(sb, s[:keep])
			}
		}
	}
	ti_keys_delete_forward(ctx, word)
}

// ti_keys_delete_forward handles the forward-delete key (rune, Alt-word, or
// atomic pill). Split from ti_keys_delete for the procedure length limit.
@(private = "file")
ti_keys_delete_forward :: proc(ctx: ^TI_Ctx, word: bool) {
	assert(ctx.sb != nil, "ti_keys_delete_forward: nil builder")
	assert(ctx.sel != nil, "ti_keys_delete_forward: nil selection")
	sb := ctx.sb
	if !ctx.caret do return
	if !(is_key_pressed(ctx.frame, .DELETE) || is_key_pressed_repeat(ctx.frame, .DELETE)) {
		return
	}
	if ti_sel_owner(ctx) {
		undo_record(ctx.frame, ctx.undo, sb, ctx.cursor, ctx.pills, .Other)
		ctx.cursor^ = selection_delete(ctx.sel, sb, ctx.pills)
	} else if ctx.cursor^ < strings.builder_len(sb^) {
		if word {
			s := strings.to_string(sb^)
			target := caret_word_right(s, ctx.cursor^)
			if target > ctx.cursor^ {
				undo_record(ctx.frame, ctx.undo, sb, ctx.cursor, ctx.pills, .Delete)
				ctx.cursor^ = ti_delete_range(ctx, ctx.cursor^, target)
			}
			return
		}
		undo_record(ctx.frame, ctx.undo, sb, ctx.cursor, ctx.pills, .Delete)
		atomic := false
		if ctx.pills != nil {
			if idx, ok := pill_starting_at(ctx.pills, ctx.cursor^); ok {
				// Atomic: delete the whole pill range in one keystroke.
				ctx.cursor^ = pill_delete_atomic(sb, ctx.pills, idx)
				atomic = true
			}
		}
		if !atomic {
			// Delete one grapheme cluster forward; masked inputs stay
			// per-rune to match their one-bullet-per-rune display.
			s := strings.to_string(sb^)
			end :=
				ctx.masked \
				? caret_next_rune(s, ctx.cursor^) \
				: caret_next_grapheme(s, ctx.cursor^)
			ctx.cursor^ = ti_delete_range(ctx, ctx.cursor^, end)
		}
	}
}

// ti_keys_enter handles Enter (submit) and Shift+Enter (newline). Returns
// true when the input was submitted this frame.
@(private = "file")
ti_keys_enter :: proc(ctx: ^TI_Ctx) -> bool {
	assert(ctx.sb != nil, "ti_keys_enter: nil builder")
	assert(ctx.sel != nil, "ti_keys_enter: nil selection")
	sb := ctx.sb
	entered := false
	shift_down := is_key_down(ctx.frame, .LEFT_SHIFT) || is_key_down(ctx.frame, .RIGHT_SHIFT)
	// Enter is the spell menu's accept key while it is open, so neither
	// submission nor newline insertion may claim it in that frame.
	spelling := spell_menu_active(ctx.spell_menu, sb)
	// Enter submits. Suppressed while the spell menu is open so Enter applies
	// the highlighted suggestion instead of sending.
	if ctx.submit == .Enter && is_key_pressed(ctx.frame, .ENTER) && !shift_down && !spelling {
		entered = true
		sel_reset(ctx.sel)
	}
	// Enter inserts a newline in a box that does not submit on Enter (a text
	// area); where Enter submits, Shift+Enter is the newline. A field that
	// swallowed Enter entirely would read as a broken text area.
	newline := ctx.submit == .Never || shift_down
	if !ctx.single_line && is_key_pressed(ctx.frame, .ENTER) && newline && !spelling {
		// The caret path clamps inside caret_insert; the legacy path obeys
		// the same per-box byte budget as every other edit, not the global
		// cap it used to check.
		if ctx.caret || ti_budget_len(ctx) < ctx.max_bytes {
			ti_insert_text(ctx, "\n", .Other)
		}
	}
	return entered
}

// ti_nav_visual moves the caret `delta` visual (soft-wrapped) rows,
// preserving the caret's pixel x across shorter lines via desired_x. The
// rows come from the same memo the renderer uses, so navigation and display
// agree by construction. Stepping past the top or bottom edge snaps to the
// text start/end - standard editor boundary behavior. Returns whether the
// caret moved vertically.
@(private = "file")
ti_nav_visual :: proc(ctx: ^TI_Ctx, delta: int) -> bool {
	assert(ctx.caret, "ti_nav_visual: caret model required")
	assert(ctx.memo != nil && delta != 0, "ti_nav_visual: invalid arguments")
	s := strings.to_string(ctx.sb^)
	font_size := ui_frame_metrics(ctx.frame).FONT_SIZE_BODY
	vlines := input_visual_lines_memo_frame(ctx.frame, ctx.memo, s, ctx.inner_w, font_size)
	row, x := input_caret_visual_frame(ctx.frame, vlines, s, ctx.cursor^, int(font_size))
	want_x := x
	if ctx.desired_x != nil {
		// Take the larger of the remembered and current x, then write it
		// back so chained vertical moves through short lines keep the
		// original column even before any horizontal refresh has run.
		want_x = max(ctx.desired_x^, x)
		ctx.desired_x^ = want_x
	}
	target := row + delta
	if target < 0 {
		if ctx.cursor^ == 0 do return false
		ctx.cursor^ = 0
		return true
	}
	if target >= len(vlines) {
		if ctx.cursor^ == len(s) do return false
		ctx.cursor^ = len(s)
		return true
	}
	vl := vlines[target]
	line := s[vl.start:vl.end]
	col := caret_pixel_to_col_frame(ctx.frame, line, want_x, font_size)
	pos := vl.start + caret_col_to_byte(line, col)
	if ctx.pills != nil do pos = pill_snap_caret(ctx.pills, pos)
	ctx.cursor^ = pos
	assert(pos >= 0 && pos <= len(s), "ti_nav_visual: cursor out of bounds")
	return true
}

// ti_nav_vert_step dispatches one vertical move: visual rows for the
// soft-wrap renderer, logical '\n' lines for masked inputs (whose single-row
// display has no soft wrap to follow).
@(private = "file")
ti_nav_vert_step :: proc(ctx: ^TI_Ctx, s: string, delta: int) -> bool {
	assert(ctx.caret, "ti_nav_vert_step: caret model required")
	assert(delta != 0, "ti_nav_vert_step: zero delta")
	if !ctx.masked do return ti_nav_visual(ctx, delta)
	row, col := caret_row_col(s, ctx.cursor^)
	want := col
	if ctx.desired_col != nil do want = max(ctx.desired_col^, col)
	target := row + delta
	if target < 0 || target >= caret_line_count(s) do return false
	ctx.cursor^ = caret_from_row_col(s, target, want)
	return true
}

// ti_keys_nav_vertical handles Up/Down/PageUp/PageDown with shift-extend.
// Suppressed while the spell menu is open, whose Up/Down navigate the
// suggestion list instead.
@(private = "file")
ti_keys_nav_vertical :: proc(ctx: ^TI_Ctx, shift: bool, s: string) -> bool {
	assert(ctx.caret, "ti_keys_nav_vertical: caret model required")
	assert(ctx.sel != nil, "ti_keys_nav_vertical: nil selection")
	sel := ctx.sel
	cursor := ctx.cursor
	moved := false
	if spell_menu_active(ctx.spell_menu, ctx.sb) do return false
	if is_key_pressed(ctx.frame, .UP) || is_key_pressed_repeat(ctx.frame, .UP) {
		nav_begin(sel, ctx.sb, cursor, shift, true)
		moved |= ti_nav_vert_step(ctx, s, -1)
		nav_end(sel, cursor, shift)
	}
	if is_key_pressed(ctx.frame, .DOWN) || is_key_pressed_repeat(ctx.frame, .DOWN) {
		nav_begin(sel, ctx.sb, cursor, shift, false)
		moved |= ti_nav_vert_step(ctx, s, 1)
		nav_end(sel, cursor, shift)
	}
	page := int(text_input_visible_lines(ctx.frame, ctx.h))
	assert(page >= 1, "ti_keys_nav_vertical: empty page")
	if is_key_pressed(ctx.frame, .PAGE_UP) || is_key_pressed_repeat(ctx.frame, .PAGE_UP) {
		nav_begin(sel, ctx.sb, cursor, shift, true)
		moved |= ti_nav_vert_step(ctx, s, -page)
		nav_end(sel, cursor, shift)
	}
	if is_key_pressed(ctx.frame, .PAGE_DOWN) || is_key_pressed_repeat(ctx.frame, .PAGE_DOWN) {
		nav_begin(sel, ctx.sb, cursor, shift, false)
		moved |= ti_nav_vert_step(ctx, s, page)
		nav_end(sel, cursor, shift)
	}
	return moved
}

// ti_keys_nav handles caret navigation keys (Left/Right/Up/Down/Home/End/
// PageUp/PageDown) with shift-extend and word jumps. Caret-aware inputs only.
@(private = "file")
ti_keys_nav :: proc(ctx: ^TI_Ctx, mods, shift: bool) {
	assert(ctx.caret, "ti_keys_nav: caret model required")
	assert(ctx.sel != nil, "ti_keys_nav: nil selection")
	sb := ctx.sb
	sel := ctx.sel
	cursor := ctx.cursor
	s := strings.to_string(sb^)
	word := is_key_down(ctx.frame, .LEFT_ALT) || is_key_down(ctx.frame, .RIGHT_ALT)

	if is_key_pressed(ctx.frame, .LEFT) || is_key_pressed_repeat(ctx.frame, .LEFT) {
		if !nav_begin(sel, sb, cursor, shift, true) {
			// Plain arrows move by grapheme cluster (whole emoji, combining
			// pairs); masked inputs stay per-rune to match their display.
			prev := ctx.masked ? caret_prev_rune : caret_prev_grapheme
			cursor^ = word ? caret_word_left(s, cursor^) : prev(s, cursor^)
			if ctx.pills != nil do cursor^ = pill_snap_left(ctx.pills, cursor^)
		}
		nav_end(sel, cursor, shift)
	}
	if is_key_pressed(ctx.frame, .RIGHT) || is_key_pressed_repeat(ctx.frame, .RIGHT) {
		if !nav_begin(sel, sb, cursor, shift, false) {
			next := ctx.masked ? caret_next_rune : caret_next_grapheme
			cursor^ = word ? caret_word_right(s, cursor^) : next(s, cursor^)
			if ctx.pills != nil do cursor^ = pill_snap_right(ctx.pills, cursor^)
		}
		nav_end(sel, cursor, shift)
	}
	moved_vert := ti_keys_nav_vertical(ctx, shift, s)
	if is_key_pressed(ctx.frame, .HOME) {
		nav_begin(sel, sb, cursor, shift, true)
		cursor^ = mods ? 0 : caret_line_start(s, cursor^)
		nav_end(sel, cursor, shift)
	}
	if is_key_pressed(ctx.frame, .END) {
		nav_begin(sel, sb, cursor, shift, false)
		cursor^ = mods ? len(s) : caret_line_end(s, cursor^)
		nav_end(sel, cursor, shift)
	}
	// Remember the column (and pixel x) for vertical movement; refresh after
	// any horizontal move or edit so Up/Down start from the right column,
	// and preserve across vertical moves so short lines don't lose it.
	if ctx.desired_col != nil && !moved_vert {
		_, c := caret_row_col(strings.to_string(sb^), cursor^)
		ctx.desired_col^ = c
	}
	if ctx.desired_x != nil && !moved_vert && !ctx.masked {
		cur := strings.to_string(sb^)
		font_size := ui_frame_metrics(ctx.frame).FONT_SIZE_BODY
		vlines := input_visual_lines_memo_frame(ctx.frame, ctx.memo, cur, ctx.inner_w, font_size)
		_, x := input_caret_visual_frame(ctx.frame, vlines, cur, cursor^, int(font_size))
		ctx.desired_x^ = x
	}
}

// ti_keys runs the whole active-input keyboard pipeline for one frame.
// Returns true when Enter submitted the input.
@(private)
ti_keys :: proc(ctx: ^TI_Ctx) -> bool {
	assert(ctx.active, "ti_keys: input not active")
	assert(ctx.sb != nil, "ti_keys: nil builder")
	mods := mod_down(ctx.frame)
	shift := is_key_down(ctx.frame, .LEFT_SHIFT) || is_key_down(ctx.frame, .RIGHT_SHIFT)
	ti_keys_select(ctx, mods, shift)
	ti_keys_insert(ctx, mods)
	ti_keys_delete(ctx, mods)
	entered := ti_keys_enter(ctx)
	if ctx.caret {
		ti_keys_nav(ctx, mods, shift)
	}
	// Safety net: drop any pill ranges left out of bounds after a
	// whole-text reset (select-all replace/cut/clear empties the buffer).
	if ctx.pills != nil && len(ctx.pills) > 0 {
		pills_drop_invalid(ctx.pills, strings.builder_len(ctx.sb^))
	}
	return entered
}

// LIB-CANDIDATE: imports only core:* and ingot:gfx.
// Text input widget: caret model, selection, clipboard, undo, mention pills,
// spellcheck, soft-wrap rendering. Extracted from widgets.odin and decomposed
// into phase procedures so each stays within Tiger Style limits.
//
// Two entry points share one implementation:
//   - text_input_box: struct-based API with per-instance Text_Input_State, so
//     multiple inputs coexist without thrashing shared caches.
//   - text_input: legacy positional signature kept source-compatible for
//     existing consumers; it routes through module-level selection/memo slots.
package ui

import "core:math"
import "core:strings"
import "core:unicode/utf8"
import rl "ingot:gfx"

// Range selection for a text input. `anchor` is where the selection started
// (mouse press / shift origin) and `extent` is the moving end; both are byte
// offsets into the owning builder and may be in either order.
Input_Sel :: struct {
	sb:              ^strings.Builder,
	anchor:          int,
	extent:          int,
	active:          bool,
	dragging:        bool,
	last_click_time: f64,
	last_click_byte: int,
	click_count:     int,
}

// Legacy module-level selection slot used by the positional text_input entry
// point. Only one such input holds a selection at a time (keyed by builder
// pointer). State-based inputs each own an Input_Sel instead.
input_sel: Input_Sel
module_ivl: Input_Vlines_Memo
module_spell_memo: Spellcheck_Memo
module_spell_menu: Spell_Menu

// input_is_selecting reports whether a legacy text input currently holds a
// selection. Used by hosts to avoid hijacking Cmd+A/Cmd+C.
input_is_selecting :: proc() -> bool {
	return input_sel.active
}

// Normalized selection range (lo <= hi) of the legacy selection slot.
input_sel_range :: proc() -> (lo, hi: int) {
	return sel_range(&input_sel)
}

input_sel_set :: proc(sb: ^strings.Builder, anchor, extent: int) {
	sel_set(&input_sel, sb, anchor, extent)
}

input_sel_clear :: proc() {
	sel_reset(&input_sel)
}

// sel_range returns the normalized (lo <= hi) range of a selection.
@(private)
sel_range :: proc(sel: ^Input_Sel) -> (lo, hi: int) {
	assert(sel != nil, "sel_range: nil selection")
	lo, hi = sel.anchor, sel.extent
	if lo > hi do lo, hi = hi, lo
	assert(lo <= hi, "sel_range: not normalized")
	return
}

@(private)
sel_set :: proc(sel: ^Input_Sel, sb: ^strings.Builder, anchor, extent: int) {
	assert(sel != nil, "sel_set: nil selection")
	assert(sb != nil, "sel_set: nil builder")
	sel.sb = sb
	sel.anchor = anchor
	sel.extent = extent
	sel.active = anchor != extent
}

@(private)
sel_reset :: proc(sel: ^Input_Sel) {
	assert(sel != nil, "sel_reset: nil selection")
	sel.active = false
	sel.dragging = false
}

// Delete the selected range from sb, dropping mention pills that intersect it
// and shifting later pills left. Returns the new caret (range start).
@(private)
selection_delete :: proc(
	sel: ^Input_Sel,
	sb: ^strings.Builder,
	pills: ^[dynamic]Mention_Span,
) -> int {
	assert(sel != nil, "selection_delete: nil selection")
	assert(sb != nil, "selection_delete: nil builder")
	old := strings.to_string(sb^)
	lo, hi := sel_range(sel)
	lo = caret_clamp(old, lo)
	hi = caret_clamp(old, hi)
	if lo >= hi {
		sel_reset(sel)
		return lo
	}
	if pills != nil {
		pills_shift_after_delete(pills, lo, hi - lo)
	}
	combined := strings.concatenate({old[:lo], old[hi:]}, context.temp_allocator)
	strings.builder_reset(sb)
	strings.write_string(sb, combined)
	sel_reset(sel)
	return lo
}

// masked_display returns a temp-allocated string of one '*' per rune of
// `text`, used by password-style inputs so measured glyph widths match what
// is actually drawn.
masked_display :: proc(text: string) -> string {
	mask_sb := strings.builder_make(context.temp_allocator)
	for _ in text do strings.write_byte(&mask_sb, '*')
	out := strings.to_string(mask_sb)
	// Why assert: one output byte per input rune is the contract callers use
	// to map masked columns back to real byte offsets.
	assert(len(out) <= len(text), "masked_display: more stars than bytes")
	assert(len(text) == 0 || len(out) > 0, "masked_display: empty mask for text")
	return out
}

// pill_delete_atomic removes pill `idx` and its text range from sb in one
// keystroke, shifting later pills left. Returns the new caret position.
@(private)
pill_delete_atomic :: proc(sb: ^strings.Builder, pills: ^[dynamic]Mention_Span, idx: int) -> int {
	assert(sb != nil && pills != nil, "pill_delete_atomic: nil argument")
	assert(idx >= 0 && idx < len(pills), "pill_delete_atomic: index out of range")
	ps, pe := pill_remove(pills, idx)
	old := strings.to_string(sb^)
	assert(ps >= 0 && pe <= len(old) && ps < pe, "pill_delete_atomic: pill range out of bounds")
	combined := strings.concatenate({old[:ps], old[pe:]}, context.temp_allocator)
	strings.builder_reset(sb)
	strings.write_string(sb, combined)
	pills_shift_after_delete(pills, ps, pe - ps)
	return ps
}

// Map a pane-local mouse position to a byte offset within the input's visible
// window. Rows clamp to the visible band; x clamps to line ends.
@(private)
input_mouse_to_byte :: proc(
	system: ^Text_System,
	vlines: []Wrap_Line,
	text: string,
	mouse: rl.Vector2,
	inner_x, y: i32,
	vis_start, vis_end: int,
) -> int {
	// Why assert: a caller passing an empty layout or an inverted visible
	// band would index vlines out of range below.
	assert(system != nil, "input_mouse_to_byte: nil text system")
	assert(len(vlines) > 0, "input_mouse_to_byte: empty visual lines")
	assert(vis_start <= vis_end, "input_mouse_to_byte: inverted visible band")
	row := vis_start + int((mouse.y - f32(y + 6)) / f32(ui_metrics(1).LINE_HEIGHT))
	if row < vis_start do row = vis_start
	if row > vis_end - 1 do row = vis_end - 1
	if row < 0 do row = 0
	if row >= len(vlines) do row = len(vlines) - 1
	vl := vlines[row]
	line := text[vl.start:vl.end]
	col := caret_pixel_to_col_with(
		system,
		line,
		i32(mouse.x) - inner_x,
		ui_metrics(1).FONT_SIZE_BODY,
	)
	return vl.start + caret_col_to_byte(line, col)
}

// Record an undo snapshot before a mutation (nil-safe).
@(private)
undo_record :: proc(
	u: ^Input_Undo,
	sb: ^strings.Builder,
	cursor: ^int,
	pills: ^[dynamic]Mention_Span,
	kind: Input_Edit_Kind,
) {
	if u == nil do return
	cur := 0
	if cursor != nil do cur = cursor^
	ps: []Mention_Span
	if pills != nil do ps = pills[:]
	input_undo_record(u, strings.to_string(sb^), cur, ps, kind, rl.GetTime())
}

// Restore the top snapshot of the undo (or redo) stack, pushing the current
// state onto the opposite stack.
@(private)
undo_apply :: proc(
	sel: ^Input_Sel,
	u: ^Input_Undo,
	sb: ^strings.Builder,
	cursor: ^int,
	pills: ^[dynamic]Mention_Span,
	redo: bool,
) {
	assert(sel != nil, "undo_apply: nil selection")
	assert(u != nil && sb != nil, "undo_apply: nil undo or builder")
	from := &u.undo
	to := &u.redo
	if redo do from, to = to, from
	if len(from) == 0 do return
	cur := 0
	if cursor != nil do cur = cursor^
	ps: []Mention_Span
	if pills != nil do ps = pills[:]
	append(to, make_input_snapshot(strings.to_string(sb^), cur, ps))
	snap := pop(from)
	strings.builder_reset(sb)
	strings.write_string(sb, snap.text)
	if cursor != nil do cursor^ = caret_clamp(snap.text, snap.cursor)
	if pills != nil {
		clear(pills)
		for p in snap.pills do append(pills, p)
	}
	input_snapshot_destroy(&snap)
	u.last_edit_kind = .None
	sel_reset(sel)
}

// Shared pre/post logic for caret navigation keys. Returns true when a
// non-shift key collapsed an active selection (Left/Right skip the move).
@(private)
nav_begin :: proc(
	sel: ^Input_Sel,
	sb: ^strings.Builder,
	cursor: ^int,
	shift, collapse_to_lo: bool,
) -> bool {
	assert(sel != nil, "nav_begin: nil selection")
	assert(sb != nil && cursor != nil, "nav_begin: nil builder or cursor")
	sel_owner := sel.active && sel.sb == sb
	if shift {
		if !sel_owner do sel_set(sel, sb, cursor^, cursor^)
		return false
	}
	if sel_owner {
		lo, hi := sel_range(sel)
		cursor^ = collapse_to_lo ? lo : hi
		sel_reset(sel)
		return true
	}
	return false
}

@(private)
nav_end :: proc(sel: ^Input_Sel, cursor: ^int, shift: bool) {
	assert(sel != nil, "nav_end: nil selection")
	assert(cursor != nil, "nav_end: nil cursor")
	if shift {
		sel.extent = cursor^
		sel.active = sel.anchor != sel.extent
	}
}

// --- Wrapped-line memo -------------------------------------------------------

// Input_Vlines_Memo caches the soft-wrapped visual lines of one input's text.
// The memo keeps a heap clone of the last text and compares by string equality
// (which short-circuits on length), so a hit costs no full-text hashing.
Input_Vlines_Memo :: struct {
	text:      string,
	width:     i32,
	font_size: i32,
	val:       []Wrap_Line,
	valid:     bool,
	owned:     bool,
}

input_visual_lines_memo :: proc(
	memo: ^Input_Vlines_Memo,
	text: string,
	inner_w: i32,
	font_size: i32 = FONT_SIZE,
) -> []Wrap_Line {
	return input_visual_lines_memo_with(&default_text_system, memo, text, inner_w, font_size)
}

// Build the soft-wrapped visual lines for an input's text using an explicit
// memo. Each logical line (split on '\n') is word-wrapped to inner_w; the
// returned ranges are absolute byte offsets into `text`. Always returns at
// least one (possibly empty) line.
input_visual_lines_memo_with :: proc(
	system: ^Text_System,
	memo: ^Input_Vlines_Memo,
	text: string,
	inner_w: i32,
	font_size: i32 = FONT_SIZE,
) -> []Wrap_Line {
	assert(system != nil, "input_visual_lines_memo: nil text system")
	assert(memo != nil, "input_visual_lines_memo: nil memo")
	assert(inner_w >= 0 && font_size > 0, "input_visual_lines_memo: invalid dimensions")
	if memo.valid && inner_w == memo.width && font_size == memo.font_size && text == memo.text {
		return memo.val
	}
	vlines := make([dynamic]Wrap_Line, context.temp_allocator)
	base := 0
	for logical in strings.split(text, "\n", context.temp_allocator) {
		// Uncached wrap: the memo above already ensures this only runs when
		// the text/width changed, and routing a large paste through the
		// global wrap_text cache would evict the transcript's layouts.
		for seg in wrap_compute_with(system, logical, inner_w, font_size) {
			append(&vlines, Wrap_Line{base + seg.start, base + seg.end})
		}
		base += len(logical) + 1 // +1 for the consumed '\n'
	}
	if len(vlines) == 0 do append(&vlines, Wrap_Line{0, 0})
	// Persist copies so the memo survives the temp allocator reset.
	if memo.owned {
		delete(memo.val)
		delete(memo.text)
	}
	memo.val = make([]Wrap_Line, len(vlines))
	copy(memo.val, vlines[:])
	memo.text = strings.clone(text)
	memo.width = inner_w
	memo.font_size = font_size
	memo.valid = true
	memo.owned = true
	return memo.val
}

// input_vlines_memo_destroy releases a memo's owned clones.
input_vlines_memo_destroy :: proc(memo: ^Input_Vlines_Memo) {
	assert(memo != nil, "input_vlines_memo_destroy: nil memo")
	if memo.owned {
		delete(memo.val)
		delete(memo.text)
	}
	memo^ = {}
}

// Map a byte offset to its visual (soft-wrapped) row and pixel x within the row.
input_caret_visual :: proc(
	system: ^Text_System,
	vlines: []Wrap_Line,
	text: string,
	pos, font_size: int,
) -> (
	row: int,
	x_px: i32,
) {
	assert(system != nil, "input_caret_visual: nil text system")
	for vl, idx in vlines {
		if pos <= vl.end {
			p := pos
			if p < vl.start do p = vl.start
			c := strings.clone_to_cstring(text[vl.start:p], context.temp_allocator)
			return idx, measure_text_with(system, c, i32(font_size))
		}
	}
	if len(vlines) > 0 {
		vl := vlines[len(vlines) - 1]
		c := strings.clone_to_cstring(text[vl.start:vl.end], context.temp_allocator)
		return len(vlines) - 1, measure_text_with(system, c, i32(font_size))
	}
	return 0, 0
}

// --- Public types ------------------------------------------------------------

Text_Input_Type :: enum i32 {
	Text,
	Email,
	Password,
}

Text_Input_Autocomplete :: enum i32 {
	None,
	Username,
	Current_Password,
	New_Password,
}

Text_Input_Semantics :: struct {
	form_id:      string,
	field_id:     string,
	name:         string,
	input_type:   Text_Input_Type,
	autocomplete: Text_Input_Autocomplete,
	focus:        ^int,
	focus_id:     int,
}

// Text_Input_Config carries per-call parameters for the struct-based API.
Text_Input_Config :: struct {
	rect:         Rect_I32,
	placeholder:  string,
	active:       bool,
	masked:       bool, // display asterisks (passwords)
	enable_pills: bool, // mention-pill support (atomic chips)
	enable_undo:  bool, // undo/redo stacks
	semantics:    Text_Input_Semantics,
}

// Text_Input_State owns everything one input instance persists across frames.
// Zero value is ready to use; call text_input_state_destroy when done.
Text_Input_State :: struct {
	cursor:      int,
	desired_col: int,
	scroll_line: int,
	sel:         Input_Sel,
	undo:        Input_Undo,
	pills:       [dynamic]Mention_Span,
	memo:        Input_Vlines_Memo,
	spell_memo:  Spellcheck_Memo,
	spell_menu:  Spell_Menu,
}

// text_input_state_destroy releases all heap state owned by a state struct.
text_input_state_destroy :: proc(st: ^Text_Input_State) {
	assert(st != nil, "text_input_state_destroy: nil state")
	input_undo_destroy(&st.undo)
	delete(st.pills)
	input_vlines_memo_destroy(&st.memo)
	spellcheck_memo_destroy(&st.spell_memo)
	spell_menu_close(&st.spell_menu)
	st^ = {}
	assert(!st.sel.active, "text_input_state_destroy: state not cleared")
}

// text_input_selecting reports whether a state-based input holds a selection.
text_input_selecting :: proc(st: ^Text_Input_State) -> bool {
	assert(st != nil, "text_input_selecting: nil state")
	return st.sel.active
}

text_input_selection_range :: proc(st: ^Text_Input_State) -> (lo, hi: int) {
	assert(st != nil, "text_input_selection_range: nil state")
	return sel_range(&st.sel)
}

text_input_selection_set :: proc(
	st: ^Text_Input_State,
	sb: ^strings.Builder,
	anchor, extent: int,
) {
	assert(st != nil && sb != nil, "text_input_selection_set: nil state or builder")
	sel_set(&st.sel, sb, anchor, extent)
}

text_input_selection_clear :: proc(st: ^Text_Input_State) {
	assert(st != nil, "text_input_selection_clear: nil state")
	sel_reset(&st.sel)
}

// --- Internal frame context --------------------------------------------------

// TI_Ctx bundles every pointer/parameter one frame of the input needs so the
// phase procedures below stay under the length limit without 14-arg calls.
@(private = "file")
TI_Ctx :: struct {
	frame:       ^Ui_Frame,
	sb:          ^strings.Builder,
	cursor:      ^int, // nil = end-anchored legacy input (no caret model)
	desired_col: ^int,
	scroll_line: ^int,
	pills:       ^[dynamic]Mention_Span,
	undo:        ^Input_Undo,
	sel:         ^Input_Sel,
	memo:        ^Input_Vlines_Memo,
	spell_memo:  ^Spellcheck_Memo,
	spell_menu:  ^Spell_Menu,
	x, y, w, h:  i32,
	rect:        rl.Rectangle,
	inner_x:     i32,
	inner_w:     i32,
	placeholder: string,
	masked:      bool,
	semantics:   Text_Input_Semantics,
	active:      bool,
	caret:       bool, // cursor != nil
}

// TI_View is the per-frame layout of the visible window of visual lines.
@(private = "file")
TI_View :: struct {
	vlines:        []Wrap_Line,
	vis_start:     int,
	vis_end:       int,
	cur_vrow:      int,
	cur_caret_x:   i32,
	visible_lines: i32,
	caret_render:  bool, // caret-aware soft-wrap renderer
	masked_caret:  bool, // caret-aware masked (password) renderer
	has_newlines:  bool,
}

@(private = "file")
ti_sel_owner :: proc(ctx: ^TI_Ctx) -> bool {
	return ctx.sel.active && ctx.sel.sb == ctx.sb
}

// ti_sync_web mirrors the input into the browser DOM (web builds) and applies
// DOM-side edits/focus back into the builder. No-op on native targets.
@(private = "file")
ti_sync_web :: proc(ctx: ^TI_Ctx) {
	assert(ctx.sb != nil, "ti_sync_web: nil builder")
	if ctx.semantics.field_id == "" do return
	web := rl.SyncWebTextInput(
		ctx.semantics.form_id,
		ctx.semantics.field_id,
		ctx.semantics.name,
		ctx.placeholder,
		strings.to_string(ctx.sb^),
		ctx.x,
		ctx.y,
		ctx.w,
		ctx.h,
		i32(ctx.semantics.input_type),
		i32(ctx.semantics.autocomplete),
		ctx.active,
	)
	if web.changed {
		strings.builder_reset(ctx.sb)
		strings.write_string(ctx.sb, web.value)
	}
	if web.focused {
		ctx.active = true
		if ctx.cursor != nil do ctx.cursor^ = caret_clamp(strings.to_string(ctx.sb^), web.cursor)
		if ctx.semantics.focus != nil do ctx.semantics.focus^ = ctx.semantics.focus_id
	}
}

// ti_semantic_push records the input in the semantic layer. Label prefers
// the field's human name over the placeholder; the field_id string is the
// stable identity when no focus link exists.
@(private = "file")
ti_semantic_push :: proc(ctx: ^TI_Ctx) {
	sem: Sem_State
	if ctx.active do sem += {.Focused}
	sfoc: Focus_Opt
	if ctx.semantics.focus != nil && ctx.semantics.focus_id > 0 {
		sfoc = {ctx.semantics.focus, ctx.semantics.focus_id}
	}
	label := ctx.semantics.name if ctx.semantics.name != "" else ctx.placeholder
	semantic_push(
		ctx.frame,
		.Text_Input,
		{ctx.x, ctx.y, ctx.w, ctx.h},
		label,
		sem,
		sfoc,
		ctx.semantics.field_id,
	)
}

// ti_keys_select handles selection ownership upkeep plus Cmd/Ctrl+A/C/X and
// undo/redo shortcuts.
@(private = "file")
ti_keys_select :: proc(ctx: ^TI_Ctx, mods, shift: bool) {
	assert(ctx.sb != nil, "ti_keys_select: nil builder")
	assert(ctx.sel != nil, "ti_keys_select: nil selection")
	sb := ctx.sb
	sel := ctx.sel
	// A selection owned by a different (now unfocused / possibly dead)
	// builder is stale — drop it so its pointer is never trusted.
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
	if !ctx.caret && ti_sel_owner(ctx) && rl.IsMouseButtonPressed(.LEFT) {
		screen_mouse := rl.GetMousePosition()
		if rl.CheckCollisionPointRec(screen_mouse, ctx.rect) &&
		   !route_occluded(ctx.frame, screen_mouse) {
			sel_reset(sel)
		}
	}
	// Select all (Cmd/Ctrl+A).
	if mods && rl.IsKeyPressed(.A) {
		if strings.builder_len(sb^) > 0 {
			sel_set(sel, sb, 0, strings.builder_len(sb^))
			if ctx.caret do ctx.cursor^ = strings.builder_len(sb^)
		}
	}
	// Copy (Cmd/Ctrl+C) — copies the selected range.
	if mods && rl.IsKeyPressed(.C) && ti_sel_owner(ctx) {
		s := strings.to_string(sb^)
		lo, hi := sel_range(sel)
		if lo < hi && hi <= len(s) {
			rl.SetClipboardText(strings.clone_to_cstring(s[lo:hi], context.temp_allocator))
		}
	}
	// Cut (Cmd/Ctrl+X) — copies the selected range then deletes it.
	if mods && rl.IsKeyPressed(.X) && ti_sel_owner(ctx) {
		s := strings.to_string(sb^)
		lo, hi := sel_range(sel)
		if lo < hi && hi <= len(s) {
			rl.SetClipboardText(strings.clone_to_cstring(s[lo:hi], context.temp_allocator))
			undo_record(ctx.undo, sb, ctx.cursor, ctx.pills, .Other)
			nc := selection_delete(sel, sb, ctx.pills)
			if ctx.caret do ctx.cursor^ = nc
		}
	}
	// Undo / Redo (Cmd/Ctrl+Z, +Shift for redo).
	if mods && ctx.undo != nil && (rl.IsKeyPressed(.Z) || rl.IsKeyPressedRepeat(.Z)) {
		undo_apply(sel, ctx.undo, sb, ctx.cursor, ctx.pills, redo = shift)
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
	for {
		ch := rl.GetCharPressed()
		if ch == 0 do break
		if mods do continue
		// Typing over a selection replaces it (one undo step).
		undo_record(ctx.undo, sb, ctx.cursor, ctx.pills, ti_sel_owner(ctx) ? .Other : .Insert)
		if ti_sel_owner(ctx) {
			nc := selection_delete(ctx.sel, sb, ctx.pills)
			if ctx.caret do ctx.cursor^ = nc
		}
		if ctx.caret {
			buf, n := utf8.encode_rune(rune(ch))
			before := ctx.cursor^
			ctx.cursor^ = caret_insert(sb, ctx.cursor^, string(buf[:n]))
			if ctx.pills != nil do pills_shift_after_insert(ctx.pills, before, ctx.cursor^ - before)
		} else if strings.builder_len(sb^) < INPUT_MAX_LEN {
			strings.write_rune(sb, rune(ch))
		}
	}
	// Handle paste (Cmd+V / Ctrl+V).
	if rl.IsKeyPressed(.V) && mods {
		clip := rl.GetClipboardText()
		if clip != nil && len(string(clip)) > 0 {
			undo_record(ctx.undo, sb, ctx.cursor, ctx.pills, .Other)
			// Pasting over a selection replaces it.
			if ti_sel_owner(ctx) {
				nc := selection_delete(ctx.sel, sb, ctx.pills)
				if ctx.caret do ctx.cursor^ = nc
			}
			clip_str := string(clip)
			if ctx.caret {
				before := ctx.cursor^
				ctx.cursor^ = caret_insert(sb, ctx.cursor^, clip_str)
				if ctx.pills != nil do pills_shift_after_insert(ctx.pills, before, ctx.cursor^ - before)
			} else {
				for ch in clip_str {
					if strings.builder_len(sb^) >= INPUT_MAX_LEN do break
					strings.write_rune(sb, ch)
				}
			}
		}
	}
}

// ti_keys_delete handles backspace and forward delete, including atomic
// mention-pill removal.
@(private = "file")
ti_keys_delete :: proc(ctx: ^TI_Ctx) {
	assert(ctx.sb != nil, "ti_keys_delete: nil builder")
	assert(ctx.sel != nil, "ti_keys_delete: nil selection")
	sb := ctx.sb
	if rl.IsKeyPressed(.BACKSPACE) || rl.IsKeyPressedRepeat(.BACKSPACE) {
		if ti_sel_owner(ctx) {
			// Delete the selected range.
			undo_record(ctx.undo, sb, ctx.cursor, ctx.pills, .Other)
			nc := selection_delete(ctx.sel, sb, ctx.pills)
			if ctx.caret do ctx.cursor^ = nc
		} else if ctx.caret {
			undo_record(ctx.undo, sb, ctx.cursor, ctx.pills, .Delete)
			if ctx.pills != nil {
				if idx, ok := pill_ending_at(ctx.pills, ctx.cursor^); ok {
					// Atomic: delete the whole pill range in one keystroke.
					ctx.cursor^ = pill_delete_atomic(sb, ctx.pills, idx)
				} else {
					before := ctx.cursor^
					ctx.cursor^ = caret_delete_prev(sb, ctx.cursor^)
					pills_shift_after_delete(ctx.pills, ctx.cursor^, before - ctx.cursor^)
				}
			} else {
				ctx.cursor^ = caret_delete_prev(sb, ctx.cursor^)
			}
		} else {
			s := strings.to_string(sb^)
			if len(s) > 0 {
				undo_record(ctx.undo, sb, ctx.cursor, ctx.pills, .Delete)
				// Remove last rune.
				last_rune_start := len(s)
				for last_rune_start > 0 {
					last_rune_start -= 1
					if (s[last_rune_start] & 0xC0) != 0x80 do break
				}
				strings.builder_reset(sb)
				strings.write_string(sb, s[:last_rune_start])
			}
		}
	}
	// Handle forward delete.
	if ctx.caret && (rl.IsKeyPressed(.DELETE) || rl.IsKeyPressedRepeat(.DELETE)) {
		if ti_sel_owner(ctx) {
			undo_record(ctx.undo, sb, ctx.cursor, ctx.pills, .Other)
			ctx.cursor^ = selection_delete(ctx.sel, sb, ctx.pills)
		} else if ctx.pills != nil {
			undo_record(ctx.undo, sb, ctx.cursor, ctx.pills, .Delete)
			if idx, ok := pill_starting_at(ctx.pills, ctx.cursor^); ok {
				// Atomic: delete the whole pill range in one keystroke.
				ctx.cursor^ = pill_delete_atomic(sb, ctx.pills, idx)
			} else {
				old_len := strings.builder_len(sb^)
				ctx.cursor^ = caret_delete_next(sb, ctx.cursor^)
				pills_shift_after_delete(
					ctx.pills,
					ctx.cursor^,
					old_len - strings.builder_len(sb^),
				)
			}
		} else {
			undo_record(ctx.undo, sb, ctx.cursor, ctx.pills, .Delete)
			ctx.cursor^ = caret_delete_next(sb, ctx.cursor^)
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
	shift_down := rl.IsKeyDown(.LEFT_SHIFT) || rl.IsKeyDown(.RIGHT_SHIFT)
	// Enter submits. Suppressed while the spell menu is open so Enter applies
	// the highlighted suggestion instead of sending.
	if rl.IsKeyPressed(.ENTER) && !shift_down && !spell_menu_active(ctx.spell_menu, sb) {
		entered = true
		sel_reset(ctx.sel)
	}
	// Shift+Enter inserts a newline.
	if rl.IsKeyPressed(.ENTER) && shift_down {
		undo_record(ctx.undo, sb, ctx.cursor, ctx.pills, .Other)
		if ti_sel_owner(ctx) {
			nc := selection_delete(ctx.sel, sb, ctx.pills)
			if ctx.caret do ctx.cursor^ = nc
		}
		if ctx.caret {
			before := ctx.cursor^
			ctx.cursor^ = caret_insert(sb, ctx.cursor^, "\n")
			if ctx.pills != nil do pills_shift_after_insert(ctx.pills, before, ctx.cursor^ - before)
		} else if strings.builder_len(sb^) < INPUT_MAX_LEN {
			strings.write_byte(sb, '\n')
		}
	}
	return entered
}

// ti_keys_nav handles caret navigation keys (Left/Right/Up/Down/Home/End)
// with shift-extend and word jumps. Caret-aware inputs only.
@(private = "file")
ti_keys_nav :: proc(ctx: ^TI_Ctx, mods, shift: bool) {
	assert(ctx.caret, "ti_keys_nav: caret model required")
	assert(ctx.sel != nil, "ti_keys_nav: nil selection")
	sb := ctx.sb
	sel := ctx.sel
	cursor := ctx.cursor
	s := strings.to_string(sb^)
	word := rl.IsKeyDown(.LEFT_ALT) || rl.IsKeyDown(.RIGHT_ALT)
	moved_vert := false

	if rl.IsKeyPressed(.LEFT) || rl.IsKeyPressedRepeat(.LEFT) {
		if !nav_begin(sel, sb, cursor, shift, true) {
			cursor^ = word ? caret_word_left(s, cursor^) : caret_prev_rune(s, cursor^)
			if ctx.pills != nil do cursor^ = pill_snap_left(ctx.pills, cursor^)
		}
		nav_end(sel, cursor, shift)
	}
	if rl.IsKeyPressed(.RIGHT) || rl.IsKeyPressedRepeat(.RIGHT) {
		if !nav_begin(sel, sb, cursor, shift, false) {
			cursor^ = word ? caret_word_right(s, cursor^) : caret_next_rune(s, cursor^)
			if ctx.pills != nil do cursor^ = pill_snap_right(ctx.pills, cursor^)
		}
		nav_end(sel, cursor, shift)
	}
	if (rl.IsKeyPressed(.UP) || rl.IsKeyPressedRepeat(.UP)) &&
	   !spell_menu_active(ctx.spell_menu, sb) {
		nav_begin(sel, sb, cursor, shift, true)
		row, col := caret_row_col(s, cursor^)
		want := col
		if ctx.desired_col != nil do want = max(ctx.desired_col^, col)
		if row > 0 {
			cursor^ = caret_from_row_col(s, row - 1, want)
			moved_vert = true
		}
		nav_end(sel, cursor, shift)
	}
	if (rl.IsKeyPressed(.DOWN) || rl.IsKeyPressedRepeat(.DOWN)) &&
	   !spell_menu_active(ctx.spell_menu, sb) {
		nav_begin(sel, sb, cursor, shift, false)
		row, col := caret_row_col(s, cursor^)
		want := col
		if ctx.desired_col != nil do want = max(ctx.desired_col^, col)
		if row < caret_line_count(s) - 1 {
			cursor^ = caret_from_row_col(s, row + 1, want)
			moved_vert = true
		}
		nav_end(sel, cursor, shift)
	}
	if rl.IsKeyPressed(.HOME) {
		nav_begin(sel, sb, cursor, shift, true)
		cursor^ = mods ? 0 : caret_line_start(s, cursor^)
		nav_end(sel, cursor, shift)
	}
	if rl.IsKeyPressed(.END) {
		nav_begin(sel, sb, cursor, shift, false)
		cursor^ = mods ? len(s) : caret_line_end(s, cursor^)
		nav_end(sel, cursor, shift)
	}
	// Remember the column for vertical movement; refresh it after any
	// horizontal move or edit so Up/Down start from the right column.
	if ctx.desired_col != nil && !moved_vert {
		_, c := caret_row_col(strings.to_string(sb^), cursor^)
		ctx.desired_col^ = c
	}
}

// ti_keys runs the whole active-input keyboard pipeline for one frame.
// Returns true when Enter submitted the input.
@(private = "file")
ti_keys :: proc(ctx: ^TI_Ctx) -> bool {
	assert(ctx.active, "ti_keys: input not active")
	assert(ctx.sb != nil, "ti_keys: nil builder")
	mods := mod_down()
	shift := rl.IsKeyDown(.LEFT_SHIFT) || rl.IsKeyDown(.RIGHT_SHIFT)
	ti_keys_select(ctx, mods, shift)
	ti_keys_insert(ctx, mods)
	ti_keys_delete(ctx)
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

// ti_layout computes the visible window of visual lines for the caret-aware
// renderer and persists the scroll position.
@(private = "file")
ti_layout :: proc(ctx: ^TI_Ctx, text: string) -> TI_View {
	assert(ctx.inner_w >= 0, "ti_layout: negative inner width")
	assert(ctx.h > 0, "ti_layout: non-positive height")
	v: TI_View
	v.has_newlines = !ctx.masked && strings.contains_rune(text, '\n')
	// Visual rows are render-only; caret navigation/history still use
	// logical lines.
	v.caret_render = ctx.caret && !ctx.masked
	v.masked_caret = ctx.caret && ctx.masked
	metrics := ui_frame_metrics(ctx.frame)
	v.visible_lines = max(1, (ctx.h - ui_frame_sc(ctx.frame, 12)) / metrics.LINE_HEIGHT)
	if !v.caret_render do return v
	v.vlines = input_visual_lines_memo_with(
		ui_frame_text(ctx.frame),
		ctx.memo,
		text,
		ctx.inner_w,
		metrics.FONT_SIZE_BODY,
	)
	v.cur_vrow, v.cur_caret_x = input_caret_visual(
		ui_frame_text(ctx.frame),
		v.vlines,
		text,
		ctx.cursor^,
		int(metrics.FONT_SIZE_BODY),
	)
	v.vis_start =
		ctx.scroll_line^ if ctx.scroll_line != nil else max(0, len(v.vlines) - int(v.visible_lines))
	if v.cur_vrow < v.vis_start do v.vis_start = v.cur_vrow
	if v.cur_vrow >= v.vis_start + int(v.visible_lines) do v.vis_start = v.cur_vrow - int(v.visible_lines) + 1
	if v.vis_start < 0 do v.vis_start = 0
	// Never scroll further than needed to fill the visible window, so the
	// view pulls back up when the input grows (e.g. after a line wraps and
	// the bar height increases).
	max_start := max(0, len(v.vlines) - int(v.visible_lines))
	if v.vis_start > max_start do v.vis_start = max_start
	if ctx.scroll_line != nil do ctx.scroll_line^ = v.vis_start
	v.vis_end = min(len(v.vlines), v.vis_start + int(v.visible_lines))
	assert(v.vis_start <= v.vis_end, "ti_layout: inverted visible band")
	return v
}

// ti_mouse_masked places the caret from a click in a masked (password) input.
@(private = "file")
ti_mouse_masked :: proc(ctx: ^TI_Ctx, text: string) {
	assert(ctx.caret, "ti_mouse_masked: caret model required")
	assert(ctx.masked, "ti_mouse_masked: masked input required")
	if !rl.IsMouseButtonPressed(.LEFT) do return
	mouse := rl.GetMousePosition()
	if route_occluded(ctx.frame, mouse) do return
	mouse = frame_to_local(ctx.frame, mouse)
	if !rl.CheckCollisionPointRec(mouse, ctx.rect) do return
	masked_text := masked_display(text)
	masked_c := strings.clone_to_cstring(masked_text, context.temp_allocator)
	font_size := ui_frame_metrics(ctx.frame).FONT_SIZE_BODY
	masked_w := measure_text_frame(ctx.frame, masked_c, font_size)
	masked_offset := max(0, masked_w - ctx.inner_w)
	col := caret_pixel_to_col_with(
		ui_frame_text(ctx.frame),
		masked_text,
		i32(mouse.x) - ctx.inner_x + masked_offset,
		font_size,
	)
	ctx.cursor^ = caret_col_to_byte(text, col)
	sel_set(ctx.sel, ctx.sb, ctx.cursor^, ctx.cursor^)
}

// ti_mouse_caret handles press (single/double/triple click), drag-extend, and
// release for the caret-aware renderer, then refreshes the caret's visual
// position so highlight and caret don't lag one frame.
@(private = "file")
ti_mouse_caret :: proc(ctx: ^TI_Ctx, text: string, v: ^TI_View) {
	assert(ctx.caret, "ti_mouse_caret: caret model required")
	assert(v.caret_render, "ti_mouse_caret: caret renderer required")
	sel := ctx.sel
	mouse := rl.GetMousePosition()
	occluded := route_occluded(ctx.frame, mouse)
	mouse = frame_to_local(ctx.frame, mouse)
	if rl.IsMouseButtonPressed(.LEFT) && !occluded {
		if rl.CheckCollisionPointRec(mouse, ctx.rect) {
			off := input_mouse_to_byte(
				ui_frame_text(ctx.frame),
				v.vlines,
				text,
				mouse,
				ctx.inner_x,
				ctx.y,
				v.vis_start,
				v.vis_end,
			)
			now := rl.GetTime()
			if now - sel.last_click_time < 0.4 && abs(off - sel.last_click_byte) <= 2 {
				sel.click_count = min(sel.click_count + 1, 3)
			} else {
				sel.click_count = 1
			}
			sel.last_click_time = now
			sel.last_click_byte = off
			switch sel.click_count {
			case 2:
				ws, we := find_word_bounds(text, off)
				sel_set(sel, ctx.sb, ws, we)
				sel.dragging = true
				ctx.cursor^ = we
			case 3:
				ls := caret_line_start(text, off)
				le := caret_line_end(text, off)
				sel_set(sel, ctx.sb, ls, le)
				sel.dragging = false
				ctx.cursor^ = le
			case:
				ctx.cursor^ = off
				if ctx.pills != nil do ctx.cursor^ = pill_snap_caret(ctx.pills, ctx.cursor^)
				sel_set(sel, ctx.sb, ctx.cursor^, ctx.cursor^)
				sel.dragging = true
			}
			if ctx.desired_col != nil {
				_, c := caret_row_col(text, ctx.cursor^)
				ctx.desired_col^ = c
			}
		} else if sel.sb == ctx.sb {
			sel_reset(sel)
		}
	}
	if sel.dragging && sel.sb == ctx.sb && rl.IsMouseButtonDown(.LEFT) {
		off := input_mouse_to_byte(
			ui_frame_text(ctx.frame),
			v.vlines,
			text,
			mouse,
			ctx.inner_x,
			ctx.y,
			v.vis_start,
			v.vis_end,
		)
		if off != sel.extent {
			sel.extent = off
			sel.active = sel.anchor != sel.extent
			ctx.cursor^ = off
		}
	}
	if sel.dragging && rl.IsMouseButtonReleased(.LEFT) {
		sel.dragging = false
		if sel.anchor == sel.extent do sel.active = false
	}
	v.cur_vrow, v.cur_caret_x = input_caret_visual(
		ui_frame_text(ctx.frame),
		v.vlines,
		text,
		ctx.cursor^,
		int(ui_frame_metrics(ctx.frame).FONT_SIZE_BODY),
	)
}

// ti_spell scans the composer for misspelled words (memoized) and opens the
// suggestions menu on right-click over one. Only the chat composer qualifies
// (caret-aware, with pills + undo).
@(private = "file")
ti_spell :: proc(ctx: ^TI_Ctx, text: string, v: ^TI_View) -> []Spell_Range {
	assert(ctx.pills != nil && ctx.undo != nil, "ti_spell: pills and undo required")
	assert(v.caret_render, "ti_spell: caret renderer required")
	squiggles := spellcheck_ranges_with(
		ui_frame_spell(ctx.frame),
		ctx.spell_memo,
		text,
		ctx.cursor^,
		ctx.pills,
	)
	if rl.IsMouseButtonPressed(.RIGHT) {
		mouse := rl.GetMousePosition()
		occluded := route_occluded(ctx.frame, mouse)
		mouse = frame_to_local(ctx.frame, mouse)
		if !occluded && rl.CheckCollisionPointRec(mouse, ctx.rect) {
			off := input_mouse_to_byte(
				ui_frame_text(ctx.frame),
				v.vlines,
				text,
				mouse,
				ctx.inner_x,
				ctx.y,
				v.vis_start,
				v.vis_end,
			)
			ws, we, misspelled := spellcheck_word_at_with(
				ui_frame_spell(ctx.frame),
				text,
				off,
				ctx.pills,
			)
			if misspelled {
				_, word_x := input_caret_visual(
					ui_frame_text(ctx.frame),
					v.vlines,
					text,
					ws,
					int(ui_frame_metrics(ctx.frame).FONT_SIZE_BODY),
				)
				spell_menu_open(
					ctx.spell_menu,
					ui_frame_spell(ctx.frame),
					ctx.sb,
					ctx.cursor,
					ctx.pills,
					ctx.undo,
					ws,
					we,
					ctx.inner_x + word_x,
					ctx.y,
				)
			} else if spell_menu_active(ctx.spell_menu, ctx.sb) {
				spell_menu_close(ctx.spell_menu)
			}
		}
	}
	return squiggles
}

// ti_render_caret_lines draws the visible window of soft-wrapped lines with
// selection highlight, pill chips, and spell squiggles.
@(private = "file")
ti_render_caret_lines :: proc(ctx: ^TI_Ctx, text: string, v: ^TI_View, squiggles: []Spell_Range) {
	assert(v.caret_render, "ti_render_caret_lines: caret renderer required")
	metrics := ui_frame_metrics(ctx.frame)
	style := ui_frame_theme(ctx.frame)
	font_size := metrics.FONT_SIZE_BODY
	line_height := metrics.LINE_HEIGHT
	assert(
		v.vis_start >= 0 && v.vis_end <= len(v.vlines),
		"ti_render_caret_lines: window out of range",
	)
	sel := ctx.sel
	render_idx: i32 = 0
	for vi := v.vis_start; vi < v.vis_end; vi += 1 {
		vl := v.vlines[vi]
		line := text[vl.start:vl.end]
		line_c := strings.clone_to_cstring(line, context.temp_allocator)
		line_y := ctx.y + ui_frame_sc(ctx.frame, 6) + render_idx * line_height
		// Selection highlight: overlap of this visual line with the range.
		if sel.active && sel.sb == ctx.sb {
			lo, hi := sel_range(sel)
			hs := max(lo, vl.start)
			he := min(hi, vl.end)
			if hs < he {
				pre_c := strings.clone_to_cstring(text[vl.start:hs], context.temp_allocator)
				hx := ctx.inner_x + measure_text_frame(ctx.frame, pre_c, font_size)
				span_c := strings.clone_to_cstring(text[hs:he], context.temp_allocator)
				hw := measure_text_frame(ctx.frame, span_c, font_size)
				rl.DrawRectangle(hx, line_y, hw, font_size, style.bg_selection)
			}
		}
		// Pill backgrounds behind any mention chips on this visual line.
		if ctx.pills != nil {
			for p in ctx.pills {
				ps := max(p.start, vl.start)
				pe := min(p.end, vl.end)
				if ps >= pe do continue
				pre_c := strings.clone_to_cstring(text[vl.start:ps], context.temp_allocator)
				seg_c := strings.clone_to_cstring(text[ps:pe], context.temp_allocator)
				px := ctx.inner_x + measure_text_frame(ctx.frame, pre_c, font_size)
				pw := measure_text_frame(ctx.frame, seg_c, font_size)
				draw_input_pill_bg_frame(ctx.frame, px, line_y, pw)
			}
		}
		draw_text_frame(ctx.frame, line_c, ctx.inner_x, line_y, font_size, style.fg_primary)
		// Redraw pill substrings in the accent color over the chip bg.
		if ctx.pills != nil {
			for p in ctx.pills {
				ps := max(p.start, vl.start)
				pe := min(p.end, vl.end)
				if ps >= pe do continue
				pre_c := strings.clone_to_cstring(text[vl.start:ps], context.temp_allocator)
				seg_c := strings.clone_to_cstring(text[ps:pe], context.temp_allocator)
				px := ctx.inner_x + measure_text_frame(ctx.frame, pre_c, font_size)
				draw_text_frame(ctx.frame, seg_c, px, line_y, font_size, style.fg_accent)
			}
		}
		// Red squiggles under misspelled words on this visual line.
		for r in squiggles {
			rs := max(r.start, vl.start)
			re := min(r.end, vl.end)
			if rs >= re do continue
			pre_c := strings.clone_to_cstring(text[vl.start:rs], context.temp_allocator)
			seg_c := strings.clone_to_cstring(text[rs:re], context.temp_allocator)
			sx := ctx.inner_x + measure_text_frame(ctx.frame, pre_c, font_size)
			sw := measure_text_frame(ctx.frame, seg_c, font_size)
			draw_squiggle(
				sx,
				line_y + font_size + ui_frame_sc(ctx.frame, 1),
				sw,
				SPELL_SQUIGGLE_COLOR,
			)
		}
		render_idx += 1
	}
}

// ti_render_multiline draws newline-split lines showing the bottom of the
// text (legacy non-caret path; cursor is always at the end).
@(private = "file")
ti_render_multiline :: proc(ctx: ^TI_Ctx, text: string, v: ^TI_View, sel_all: bool) {
	assert(v.has_newlines, "ti_render_multiline: multiline text required")
	assert(v.visible_lines > 0, "ti_render_multiline: no visible lines")
	metrics := ui_frame_metrics(ctx.frame)
	style := ui_frame_theme(ctx.frame)
	font_size := metrics.FONT_SIZE_BODY
	line_height := metrics.LINE_HEIGHT
	lines := strings.split(text, "\n", context.temp_allocator)
	start_line := max(0, i32(len(lines)) - v.visible_lines)
	render_idx: i32 = 0
	for i := start_line; i < i32(len(lines)); i += 1 {
		line := lines[i]
		line_c := strings.clone_to_cstring(line, context.temp_allocator)
		line_y := ctx.y + ui_frame_sc(ctx.frame, 6) + render_idx * line_height
		// Only the last line gets horizontal scrolling (cursor is at the end).
		if i == i32(len(lines)) - 1 {
			line_pixel_w := measure_text_frame(ctx.frame, line_c, font_size)
			line_offset: i32 = 0
			if line_pixel_w > ctx.inner_w {
				line_offset = line_pixel_w - ctx.inner_w
			}
			if sel_all {
				hl_w := min(line_pixel_w, ctx.inner_w)
				rl.DrawRectangle(ctx.inner_x, line_y, hl_w, font_size, style.bg_selection)
			}
			draw_text_frame(
				ctx.frame,
				line_c,
				ctx.inner_x - line_offset,
				line_y,
				font_size,
				style.fg_primary,
			)
		} else {
			if sel_all {
				hl_w := min(measure_text_frame(ctx.frame, line_c, font_size), ctx.inner_w)
				rl.DrawRectangle(ctx.inner_x, line_y, hl_w, font_size, style.bg_selection)
			}
			draw_text_frame(ctx.frame, line_c, ctx.inner_x, line_y, font_size, style.fg_primary)
		}
		render_idx += 1
	}
}

// ti_render_single draws the single-line (optionally masked) path with
// horizontal end-scroll.
@(private = "file")
ti_render_single :: proc(ctx: ^TI_Ctx, text: string, sel_all: bool) {
	assert(len(text) > 0, "ti_render_single: empty text")
	assert(ctx.inner_w >= 0, "ti_render_single: negative inner width")
	metrics := ui_frame_metrics(ctx.frame)
	style := ui_frame_theme(ctx.frame)
	font_size := metrics.FONT_SIZE_BODY
	display_text := masked_display(text) if ctx.masked else text
	display_c := strings.clone_to_cstring(display_text, context.temp_allocator)
	text_pixel_w := measure_text_frame(ctx.frame, display_c, font_size)
	text_offset: i32 = 0
	if text_pixel_w > ctx.inner_w {
		text_offset = text_pixel_w - ctx.inner_w
	}
	if sel_all {
		hl_w := min(text_pixel_w, ctx.inner_w)
		rl.DrawRectangle(
			ctx.inner_x,
			ctx.y + (ctx.h - font_size) / 2,
			hl_w,
			font_size,
			style.bg_selection,
		)
	}
	draw_text_frame(
		ctx.frame,
		display_c,
		ctx.inner_x - text_offset,
		ctx.y + (ctx.h - font_size) / 2,
		font_size,
		style.fg_primary,
	)
}

// ti_draw_caret draws the blinking caret and updates the OS text-input rect
// so IME candidate windows track it. Caret position is computed every frame
// (not only blink-on); only the caret line itself blinks.
@(private = "file")
ti_draw_caret :: proc(ctx: ^TI_Ctx, text: string, v: ^TI_View) {
	assert(ctx.active, "ti_draw_caret: input not active")
	assert(ctx.h > 0, "ti_draw_caret: non-positive height")
	metrics := ui_frame_metrics(ctx.frame)
	style := ui_frame_theme(ctx.frame)
	font_size := metrics.FONT_SIZE_BODY
	line_height := metrics.LINE_HEIGHT
	t := rl.GetTime()
	blink_on := true
	if !style.reduced_motion {
		// Blink is time-driven: in event-driven frame mode nothing else
		// forces a repaint while the user pauses typing, so schedule one at
		// the next half-second toggle boundary. Reduced motion keeps the
		// caret steady (no blink, no scheduled repaints).
		rl.RequestRedrawIn(0.5 - math.mod(t, 0.5))
		blink_on = int(t * 2) % 2 == 0
	}
	if v.caret_render {
		// Caret at its true visual (row, x) within the visible window.
		if v.cur_vrow >= v.vis_start && v.cur_vrow < v.vis_end {
			cursor_x := ctx.inner_x + v.cur_caret_x
			cursor_line_y :=
				ctx.y + ui_frame_sc(ctx.frame, 6) + i32(v.cur_vrow - v.vis_start) * line_height
			rl.SetTextInputRect(cursor_x, cursor_line_y, 1, font_size)
			if blink_on {
				rl.DrawLine(
					cursor_x,
					cursor_line_y,
					cursor_x,
					cursor_line_y + font_size,
					style.fg_accent,
				)
			}
		}
		return
	}
	if v.has_newlines {
		// Multiline cursor: position at end of last line.
		lines := strings.split(text, "\n", context.temp_allocator)
		last_line := lines[len(lines) - 1]
		last_line_c := strings.clone_to_cstring(last_line, context.temp_allocator)
		cursor_text_w := measure_text_frame(ctx.frame, last_line_c, font_size)
		cursor_offset: i32 = 0
		if cursor_text_w > ctx.inner_w {
			cursor_offset = cursor_text_w - ctx.inner_w
		}
		cursor_x := ctx.inner_x + cursor_text_w - cursor_offset
		visible_count := min(i32(len(lines)), v.visible_lines)
		cursor_line_y := ctx.y + ui_frame_sc(ctx.frame, 6) + (visible_count - 1) * line_height
		rl.SetTextInputRect(cursor_x, cursor_line_y, 1, font_size)
		if blink_on {
			rl.DrawLine(
				cursor_x,
				cursor_line_y,
				cursor_x,
				cursor_line_y + font_size,
				style.fg_accent,
			)
		}
		return
	}
	ti_draw_caret_single(ctx, text, blink_on)
}

// ti_draw_caret_single draws the caret for the single-line render path,
// mapping the byte cursor through the (possibly masked) display string.
@(private = "file")
ti_draw_caret_single :: proc(ctx: ^TI_Ctx, text: string, blink_on: bool) {
	assert(ctx.active, "ti_draw_caret_single: input not active")
	assert(ctx.h > 0, "ti_draw_caret_single: non-positive height")
	font_size := ui_frame_metrics(ctx.frame).FONT_SIZE_BODY
	style := ui_frame_theme(ctx.frame)
	display_for_cursor := masked_display(text) if ctx.masked else text
	cursor_text_w := measure_text_frame(
		ctx.frame,
		strings.clone_to_cstring(display_for_cursor, context.temp_allocator),
		font_size,
	)
	cursor_offset: i32 = 0
	if cursor_text_w > ctx.inner_w {
		cursor_offset = cursor_text_w - ctx.inner_w
	}
	cursor_prefix := display_for_cursor
	if ctx.caret {
		col := 0
		byte := 0
		for byte < ctx.cursor^ {
			byte = caret_next_rune(text, byte)
			col += 1
		}
		prefix_end := caret_col_to_byte(display_for_cursor, col)
		cursor_prefix = display_for_cursor[:prefix_end]
	}
	cursor_prefix_w := measure_text_frame(
		ctx.frame,
		strings.clone_to_cstring(cursor_prefix, context.temp_allocator),
		font_size,
	)
	cursor_x := ctx.inner_x + cursor_prefix_w - cursor_offset
	rl.SetTextInputRect(cursor_x, ctx.y + 5, 1, ctx.h - 10)
	if blink_on {
		inset := ui_frame_sc(ctx.frame, 5)
		rl.DrawLine(cursor_x, ctx.y + inset, cursor_x, ctx.y + ctx.h - inset, style.fg_accent)
	}
}

// ti_run drives one frame of the input: web sync, chrome, keys, layout,
// mouse, spellcheck, render, caret, spell-menu popup. Returns true when
// Enter submitted the input.
@(private = "file")
ti_run :: proc(ctx: ^TI_Ctx) -> bool {
	assert(ctx.sb != nil, "ti_run: nil builder")
	assert(ctx.sel != nil && ctx.memo != nil, "ti_run: nil selection or memo")
	ti_sync_web(ctx)
	ti_semantic_push(ctx)
	metrics := ui_frame_metrics(ctx.frame)
	style := ui_frame_theme(ctx.frame)
	font_size := metrics.FONT_SIZE_BODY
	bg := style.bg_input if ctx.active else style.bg_secondary
	rl.DrawRectangleRec(ctx.rect, bg)
	rl.DrawRectangleLinesEx(
		ctx.rect,
		ui_frame_scf(ctx.frame, 1),
		style.border_color if !ctx.active else style.fg_accent,
	)

	entered := false
	if ctx.active {
		entered = ti_keys(ctx)
	}

	// Clip all drawing to the input rect interior.
	begin_pane_scissor(ctx.frame, ctx.inner_x, ctx.y, ctx.inner_w, ctx.h)
	text := strings.to_string(ctx.sb^)
	v := ti_layout(ctx, text)

	// Mouse selection (caret inputs): press places the caret / starts a drag,
	// double-click selects a word, triple-click the logical line, drag extends
	// by character. Mouse is converted to pane-local coordinates because split
	// panes draw rlgl-translated while the mouse is in screen space.
	if ctx.active && v.masked_caret {
		ti_mouse_masked(ctx, text)
	}
	if ctx.active && v.caret_render {
		ti_mouse_caret(ctx, text, &v)
	}

	spell_squiggles: []Spell_Range
	if ctx.active && v.caret_render && ctx.pills != nil && ctx.undo != nil {
		spell_squiggles = ti_spell(ctx, text, &v)
	}

	// Legacy (non-caret) render paths only show a highlight when the selection
	// covers the whole text (Cmd+A on simple inputs).
	sel := ctx.sel
	sel_all :=
		sel.active &&
		sel.sb == ctx.sb &&
		min(sel.anchor, sel.extent) == 0 &&
		max(sel.anchor, sel.extent) == len(text)

	if len(text) == 0 {
		ph_c := strings.clone_to_cstring(ctx.placeholder, context.temp_allocator)
		draw_text_frame(
			ctx.frame,
			ph_c,
			ctx.inner_x,
			ctx.y + (ctx.h - font_size) / 2,
			font_size,
			style.fg_secondary,
		)
	} else if v.caret_render {
		ti_render_caret_lines(ctx, text, &v, spell_squiggles)
	} else if v.has_newlines {
		ti_render_multiline(ctx, text, &v, sel_all)
	} else {
		ti_render_single(ctx, text, sel_all)
	}

	if ctx.active {
		ti_draw_caret(ctx, text, &v)
	}
	rl.EndScissorMode()

	// Suggestions popup for a right-clicked misspelled word. Drawn after the
	// scissor ends so it renders unclipped above the input box.
	if spell_menu_active(ctx.spell_menu, ctx.sb) {
		draw_spell_menu(ctx.frame, ctx.spell_menu, ui_frame_spell(ctx.frame), ctx.x, ctx.y, ctx.w)
	}
	return entered
}

// --- Entry points ------------------------------------------------------------

// text_input_box draws a text input using caller-owned per-instance state, so
// any number of inputs coexist without shared-cache thrash. Always caret-
// aware. Returns true if Enter was pressed.
text_input_box :: proc(
	frame: ^Ui_Frame,
	cfg: Text_Input_Config,
	sb: ^strings.Builder,
	st: ^Text_Input_State,
) -> bool {
	assert(sb != nil, "text_input_box: nil builder")
	assert(st != nil, "text_input_box: nil state")
	assert(cfg.rect.w > 0 && cfg.rect.h > 0, "text_input_box: empty rect")
	ctx := TI_Ctx {
		frame       = frame,
		sb          = sb,
		cursor      = &st.cursor,
		desired_col = &st.desired_col,
		scroll_line = &st.scroll_line,
		pills       = &st.pills if cfg.enable_pills else nil,
		undo        = &st.undo if cfg.enable_undo else nil,
		sel         = &st.sel,
		memo        = &st.memo,
		spell_memo  = &st.spell_memo,
		spell_menu  = &st.spell_menu,
		x           = cfg.rect.x,
		y           = cfg.rect.y,
		w           = cfg.rect.w,
		h           = cfg.rect.h,
		rect        = rl.Rectangle {
			f32(cfg.rect.x),
			f32(cfg.rect.y),
			f32(cfg.rect.w),
			f32(cfg.rect.h),
		},
		inner_x     = cfg.rect.x + PADDING,
		inner_w     = cfg.rect.w - PADDING * 2,
		placeholder = cfg.placeholder,
		masked      = cfg.masked,
		semantics   = cfg.semantics,
		active      = cfg.active,
		caret       = true,
	}
	return ti_run(&ctx)
}

// Draw a text input box (legacy positional API). Returns true if Enter was
// pressed. When masked is true, displays asterisks instead of actual text
// (for passwords). `cursor` is an optional byte-offset caret; pass nil for
// single-line, end-anchored inputs (file browser, token field). When non-nil
// the input supports Left/Right/Up/Down/Home/End navigation and inserts/
// deletes at the caret. `desired_col` (optional) remembers the rune column
// across vertical moves and `scroll_line` (optional) persists the top visible
// logical line. Selection and the wrap memo live in module-level slots, so
// only one legacy input should be focused at a time; new code should prefer
// text_input_box.
text_input :: proc(
	frame: ^Ui_Frame,
	x, y, w, h: i32,
	sb: ^strings.Builder,
	placeholder: string,
	active: bool,
	masked: bool = false,
	cursor: ^int = nil,
	desired_col: ^int = nil,
	scroll_line: ^int = nil,
	pills: ^[dynamic]Mention_Span = nil,
	undo: ^Input_Undo = nil,
	semantics: Text_Input_Semantics = {},
) -> bool {
	assert(sb != nil, "text_input: nil builder")
	assert(w > 0 && h > 0, "text_input: empty rect")
	ctx := TI_Ctx {
		frame       = frame,
		sb          = sb,
		cursor      = cursor,
		desired_col = desired_col,
		scroll_line = scroll_line,
		pills       = pills,
		undo        = undo,
		sel         = &input_sel,
		memo        = &module_ivl,
		spell_memo  = &module_spell_memo,
		spell_menu  = &module_spell_menu,
		x           = x,
		y           = y,
		w           = w,
		h           = h,
		rect        = rl.Rectangle{f32(x), f32(y), f32(w), f32(h)},
		inner_x     = x + PADDING,
		inner_w     = w - PADDING * 2,
		placeholder = placeholder,
		masked      = masked,
		semantics   = semantics,
		active      = active,
		caret       = cursor != nil,
	}
	return ti_run(&ctx)
}

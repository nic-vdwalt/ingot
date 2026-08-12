// LIB-CANDIDATE: imports only core:*.
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

// Vertical padding above the first text line inside the box. Mouse
// hit-testing and rendering must resolve this through one shared constant
// (scaled per frame) or clicks map to the wrong row at UI scales other
// than 1.
@(private = "file")
TI_PAD_TOP :: 6
// Total vertical padding (top + bottom) a box spends around its text; the
// visible line count is derived from the height that remains.
@(private = "file")
TI_PAD_VERT :: TI_PAD_TOP * 2
// Inset of the single-line caret (and its IME rect) from the box edges.
@(private = "file")
TI_CARET_INSET :: 5


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
	frame: ^Ui_Frame,
	vlines: []Wrap_Line,
	text: string,
	mouse: Vector2,
	inner_x, y: i32,
	vis_start, vis_end: int,
) -> int {
	// Why assert: a caller passing an empty layout or an inverted visible
	// band would index vlines out of range below.
	assert(frame != nil && frame.open, "input_mouse_to_byte: invalid frame")
	metrics := ui_frame_metrics(frame)
	assert(len(vlines) > 0, "input_mouse_to_byte: empty visual lines")
	assert(vis_start <= vis_end, "input_mouse_to_byte: inverted visible band")
	// The same scaled padding the renderer offsets lines by; an unscaled
	// literal here made clicks land one row off at non-1 UI scales.
	pad := ui_frame_sc(frame, TI_PAD_TOP)
	row := vis_start + int((mouse.y - f32(y + pad)) / f32(metrics.LINE_HEIGHT))
	if row < vis_start do row = vis_start
	if row > vis_end - 1 do row = vis_end - 1
	if row < 0 do row = 0
	if row >= len(vlines) do row = len(vlines) - 1
	vl := vlines[row]
	line := text[vl.start:vl.end]
	col := caret_pixel_to_col_frame(frame, line, i32(mouse.x) - inner_x, metrics.FONT_SIZE_BODY)
	return vl.start + caret_col_to_byte(line, col)
}

// Record an undo snapshot before a mutation (nil-safe).
@(private)
undo_record :: proc(
	frame: ^Ui_Frame,
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
	input_undo_record(u, strings.to_string(sb^), cur, ps, kind, frame_input(frame).time)
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

@(private = "file")
input_vlines_memo_matches :: proc(
	memo: ^Input_Vlines_Memo,
	text: string,
	width, font_size: i32,
) -> bool {
	assert(memo != nil, "input_vlines_memo_matches: nil memo")
	return memo.valid && width == memo.width && font_size == memo.font_size && text == memo.text
}

@(private = "file")
input_vlines_memo_release :: proc(memo: ^Input_Vlines_Memo) {
	assert(memo != nil, "input_vlines_memo_release: nil memo")
	if memo.owned {
		if len(memo.val) > 0 do delete(memo.val)
		if len(memo.text) > 0 do delete(memo.text)
	}
	memo.val = nil
	memo.text = ""
	memo.valid = false
	memo.owned = false
}

@(private = "file")
input_vlines_memo_commit :: proc(
	memo: ^Input_Vlines_Memo,
	text: string,
	width, font_size: i32,
	vlines: []Wrap_Line,
) -> []Wrap_Line {
	assert(memo != nil, "input_vlines_memo_commit: nil memo")
	assert(len(vlines) > 0, "input_vlines_memo_commit: empty lines")
	input_vlines_memo_release(memo)
	memo.val = make([]Wrap_Line, len(vlines))
	copy(memo.val, vlines)
	memo.text = strings.clone(text)
	memo.width = width
	memo.font_size = font_size
	memo.valid = true
	memo.owned = true
	assert(len(memo.val) == len(vlines))
	return memo.val
}

// Build the soft-wrapped visual lines for an input's text using an explicit
// memo. Each logical line (split on '\n') is word-wrapped to inner_w; the
// returned ranges are absolute byte offsets into `text`. Always returns at
// least one (possibly empty) line.
//
// The wrap callee is threaded as a raw pointer + proc so the Text_System and
// Ui_Frame entry points share one implementation (including the incremental
// splice below) instead of drifting as line-for-line duplicates.
@(private = "file")
TI_Wrap_Fn :: #type proc(data: rawptr, logical: string, max_width, font_size: i32) -> []Wrap_Line

@(private = "file")
ti_wrap_with :: proc(data: rawptr, logical: string, max_width, font_size: i32) -> []Wrap_Line {
	assert(data != nil, "ti_wrap_with: nil text system")
	assert(font_size > 0, "ti_wrap_with: invalid font size")
	return wrap_compute_with((^Text_System)(data), logical, max_width, font_size)
}

@(private = "file")
ti_wrap_frame :: proc(data: rawptr, logical: string, max_width, font_size: i32) -> []Wrap_Line {
	assert(data != nil, "ti_wrap_frame: nil frame")
	assert(font_size > 0, "ti_wrap_frame: invalid font size")
	return wrap_compute_frame((^Ui_Frame)(data), logical, max_width, font_size)
}

// input_vlines_wrap_region appends the soft-wrapped lines of text[lo:hi]
// (split on '\n') to out, with byte ranges absolute into `text`.
@(private = "file")
input_vlines_wrap_region :: proc(
	wrap_data: rawptr,
	wrap_fn: TI_Wrap_Fn,
	out: ^[dynamic]Wrap_Line,
	text: string,
	lo, hi: int,
	inner_w, font_size: i32,
) {
	assert(wrap_fn != nil, "input_vlines_wrap_region: nil wrap fn")
	assert(0 <= lo && lo <= hi && hi <= len(text), "input_vlines_wrap_region: bad region")
	base := lo
	for logical in strings.split(text[lo:hi], "\n", context.temp_allocator) {
		// Uncached wrap: the memo already ensures this only runs when the
		// text/width changed, and routing a large paste through the global
		// wrap_text cache would evict the transcript's layouts.
		for seg in wrap_fn(wrap_data, logical, inner_w, font_size) {
			append(out, Wrap_Line{base + seg.start, base + seg.end})
		}
		base += len(logical) + 1 // +1 for the consumed '\n'
	}
}

// input_vlines_incremental rewraps only the logical lines an edit touched,
// reusing the memo's lines before and after the change. Wrapping is
// context-free per logical line (each is wrapped in isolation), so splicing
// is exact; the win is that typing in a large document re-measures one
// logical line instead of all of them.
@(private = "file")
input_vlines_incremental :: proc(
	wrap_data: rawptr,
	wrap_fn: TI_Wrap_Fn,
	memo: ^Input_Vlines_Memo,
	text: string,
	inner_w, font_size: i32,
) -> []Wrap_Line {
	assert(memo != nil, "input_vlines_incremental: nil memo")
	assert(memo.valid && memo.owned, "input_vlines_incremental: cold memo")
	assert(
		memo.width == inner_w && memo.font_size == font_size,
		"input_vlines_incremental: geometry changed",
	)
	old := memo.text
	// Common prefix/suffix in bytes; the suffix may not overlap the prefix.
	limit := min(len(old), len(text))
	p := 0
	for p < limit && old[p] == text[p] do p += 1
	s := 0
	for s < limit - p && old[len(old) - 1 - s] == text[len(text) - 1 - s] do s += 1
	// Widen the changed region to whole logical lines. The bytes before `ls`
	// and the trailing `s` bytes are identical in both strings, so line
	// boundaries found in one hold in the other.
	ls := strings.last_index_byte(text[:p], '\n') + 1
	new_hi := len(text) - s
	old_hi := len(old) - s
	rel := strings.index_byte(text[new_hi:], '\n')
	new_end := len(text) if rel < 0 else new_hi + rel
	old_end := len(old) if rel < 0 else old_hi + rel
	delta := len(text) - len(old)
	vlines := make([dynamic]Wrap_Line, context.temp_allocator)
	// Lines wholly before the changed logical line: their ranges end before
	// the '\n' that precedes `ls`, so `end < ls` is an exact cut.
	for vl in memo.val {
		if vl.end >= ls do break
		append(&vlines, vl)
	}
	input_vlines_wrap_region(wrap_data, wrap_fn, &vlines, text, ls, new_end, inner_w, font_size)
	// Lines wholly after the changed region start past the '\n' at old_end;
	// the shared suffix shifts by the edit's byte delta.
	for vl in memo.val {
		if vl.start <= old_end do continue
		append(&vlines, Wrap_Line{vl.start + delta, vl.end + delta})
	}
	if len(vlines) == 0 do append(&vlines, Wrap_Line{0, 0})
	// Oracle: a splice producing out-of-bounds or backward ranges would
	// corrupt every caret/selection mapping downstream.
	prev := 0
	for vl in vlines {
		assert(vl.start >= prev && vl.start <= vl.end, "input_vlines_incremental: unordered")
		assert(vl.end <= len(text), "input_vlines_incremental: out of bounds")
		prev = vl.start
	}
	return vlines[:]
}

@(private = "file")
input_vlines_memo_build :: proc(
	wrap_data: rawptr,
	wrap_fn: TI_Wrap_Fn,
	memo: ^Input_Vlines_Memo,
	text: string,
	inner_w: i32,
	font_size: i32,
) -> []Wrap_Line {
	assert(memo != nil, "input_vlines_memo_build: nil memo")
	assert(inner_w >= 0 && font_size > 0, "input_vlines_memo_build: invalid dimensions")
	if input_vlines_memo_matches(memo, text, inner_w, font_size) do return memo.val
	// A warm memo whose geometry still matches means only the text changed:
	// splice around the edit instead of rewrapping the whole document.
	if memo.valid && memo.owned && memo.width == inner_w && memo.font_size == font_size {
		spliced := input_vlines_incremental(wrap_data, wrap_fn, memo, text, inner_w, font_size)
		return input_vlines_memo_commit(memo, text, inner_w, font_size, spliced)
	}
	vlines := make([dynamic]Wrap_Line, context.temp_allocator)
	input_vlines_wrap_region(wrap_data, wrap_fn, &vlines, text, 0, len(text), inner_w, font_size)
	if len(vlines) == 0 do append(&vlines, Wrap_Line{0, 0})
	// Persist copies so the memo survives the temp allocator reset.
	return input_vlines_memo_commit(memo, text, inner_w, font_size, vlines[:])
}

input_visual_lines_memo_with :: proc(
	system: ^Text_System,
	memo: ^Input_Vlines_Memo,
	text: string,
	inner_w: i32,
	font_size: i32,
) -> []Wrap_Line {
	assert(system != nil, "input_visual_lines_memo: nil text system")
	assert(memo != nil, "input_visual_lines_memo: nil memo")
	return input_vlines_memo_build(system, ti_wrap_with, memo, text, inner_w, font_size)
}

input_visual_lines_memo_frame :: proc(
	frame: ^Ui_Frame,
	memo: ^Input_Vlines_Memo,
	text: string,
	inner_w: i32,
	font_size: i32,
) -> []Wrap_Line {
	assert(frame != nil && frame.open, "input_visual_lines_memo_frame: invalid frame")
	assert(memo != nil, "input_visual_lines_memo_frame: nil memo")
	return input_vlines_memo_build(frame, ti_wrap_frame, memo, text, inner_w, font_size)
}

// input_vlines_memo_destroy releases a memo's owned clones.
input_vlines_memo_destroy :: proc(memo: ^Input_Vlines_Memo) {
	assert(memo != nil, "input_vlines_memo_destroy: nil memo")
	input_vlines_memo_release(memo)
	assert(!memo.owned && !memo.valid, "input_vlines_memo_destroy: live memo")
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

input_caret_visual_frame :: proc(
	frame: ^Ui_Frame,
	vlines: []Wrap_Line,
	text: string,
	pos, font_size: int,
) -> (
	row: int,
	x_px: i32,
) {
	assert(frame != nil && frame.open, "input_caret_visual_frame: invalid frame")
	assert(font_size > 0, "input_caret_visual_frame: invalid font size")
	for vl, idx in vlines {
		if pos <= vl.end {
			p := pos
			if p < vl.start do p = vl.start
			prefix := strings.clone_to_cstring(text[vl.start:p], context.temp_allocator)
			return idx, measure_text_frame(frame, prefix, i32(font_size))
		}
	}
	if len(vlines) > 0 {
		vl := vlines[len(vlines) - 1]
		line := strings.clone_to_cstring(text[vl.start:vl.end], context.temp_allocator)
		return len(vlines) - 1, measure_text_frame(frame, line, i32(font_size))
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

Text_Input_Submit :: enum u8 {
	Enter,
	Never,
}

// text_input_visible_lines reports how many lines of text a box of this pixel
// height can show. It is the same expression ti_layout uses to size the
// visible band, so behaviour and rendering can never disagree about whether a
// box is one line tall.
text_input_visible_lines :: proc(frame: ^Ui_Frame, height: i32) -> i32 {
	assert(frame != nil, "text_input_visible_lines: nil frame")
	assert(height > 0, "text_input_visible_lines: non-positive height")
	metrics := ui_frame_metrics(frame)
	assert(metrics.LINE_HEIGHT > 0, "text_input_visible_lines: non-positive line height")
	return max(1, (height - ui_frame_sc(frame, TI_PAD_VERT)) / metrics.LINE_HEIGHT)
}

// text_input_default_submit picks the Enter behaviour a box of this height
// should have. A box showing two or more lines is a text area, where every
// platform inserts a newline on Enter; a one-line field submits.
text_input_default_submit :: proc(frame: ^Ui_Frame, height: i32) -> Text_Input_Submit {
	return .Never if text_input_visible_lines(frame, height) > 1 else .Enter
}

Text_Input_Filter :: #type proc(value: rune) -> bool

Text_Input_Semantics :: struct {
	form_id:      string,
	field_id:     string,
	name:         string,
	input_type:   Text_Input_Type,
	autocomplete: Text_Input_Autocomplete,
	focus:        ^int,
	focus_id:     int,
	widget:       Widget_Id,
}

// Text_Input_Config carries per-call parameters for the struct-based API.
Text_Input_Config :: struct {
	rect:         Rect_I32,
	placeholder:  string,
	active:       bool,
	masked:       bool, // display asterisks (passwords)
	enable_pills: bool, // mention-pill support (atomic chips)
	enable_undo:  bool, // undo/redo stacks
	max_bytes:    int, // zero uses INPUT_MAX_LEN
	single_line:  bool,
	submit:       Text_Input_Submit,
	filter:       Text_Input_Filter,
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

text_input_spell_menu_active :: proc(st: ^Text_Input_State, sb: ^strings.Builder) -> bool {
	assert(st != nil && sb != nil, "text_input_spell_menu_active: nil state or builder")
	return spell_menu_active(&st.spell_menu, sb)
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
	rect:        Rectangle,
	inner_x:     i32,
	inner_w:     i32,
	placeholder: string,
	masked:      bool,
	max_bytes:   int,
	single_line: bool,
	submit:      Text_Input_Submit,
	filter:      Text_Input_Filter,
	semantics:   Text_Input_Semantics,
	active:      bool,
	caret:       bool, // cursor != nil
}

// TI_View is the per-frame layout of the visible window of visual lines.
@(private = "file")
TI_View :: struct {
	vlines:        []Wrap_Line,
	masked_text:   string, // per-frame star string for masked inputs
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
// DOM-side edits/focus back into the builder. No-op wherever no web form
// backend is installed (native targets, headless tests).
@(private = "file")
ti_sync_web :: proc(ctx: ^TI_Ctx) {
	assert(ctx.sb != nil, "ti_sync_web: nil builder")
	backend := ui_frame_runtime(ctx.frame).web_form
	if backend.sync_text_input == nil do return
	sem := ctx.semantics
	if sem.form_id == "" || sem.field_id == "" do return
	result := backend.sync_text_input(
		backend.data,
		sem.form_id,
		sem.field_id,
		sem.name,
		ctx.placeholder,
		strings.to_string(ctx.sb^),
		ctx.x,
		ctx.y,
		ctx.w,
		ctx.h,
		i32(sem.input_type),
		i32(sem.autocomplete),
		ctx.active,
	)
	if !result.changed do return
	value := result.value
	// DOM edits obey the same byte budget as keyboard edits; clamp on a rune
	// boundary so a truncated autofill never splits a codepoint.
	if len(value) > ctx.max_bytes do value = value[:caret_clamp(value, ctx.max_bytes)]
	strings.builder_reset(ctx.sb)
	strings.write_string(ctx.sb, value)
	if ctx.cursor != nil do ctx.cursor^ = caret_clamp(value, result.cursor)
	if ctx.sel.active && ctx.sel.sb == ctx.sb do sel_reset(ctx.sel)
}

// ti_semantic_push records the input in the semantic layer. Label prefers
// the field's human name over the placeholder; the field_id string is the
// stable identity when no focus link exists.
@(private = "file")
ti_semantic_push :: proc(ctx: ^TI_Ctx) {
	sem: Sem_State
	if ctx.active do sem += {.Focused}
	if ctx.masked do sem += {.Password}
	if !ctx.single_line do sem += {.Multiline}
	sfoc: Focus_Opt
	if ctx.semantics.focus != nil && ctx.semantics.focus_id > 0 {
		sfoc = {ctx.semantics.focus, ctx.semantics.focus_id}
	}
	label := ctx.semantics.name if ctx.semantics.name != "" else ctx.placeholder
	text_value := "" if ctx.masked else strings.to_string(ctx.sb^)
	selection_start, selection_end: i32
	if ti_sel_owner(ctx) {
		lo, hi := sel_range(ctx.sel)
		selection_start = i32(lo)
		selection_end = i32(hi)
	}
	semantic_push(
		ctx.frame,
		.Text_Input,
		{ctx.x, ctx.y, ctx.w, ctx.h},
		label,
		sem,
		sfoc,
		ctx.semantics.field_id,
		text_value = text_value,
		selection_start = selection_start,
		selection_end = selection_end,
		widget = ctx.semantics.widget,
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

// ti_keys_delete handles backspace and forward delete, including atomic
// mention-pill removal. Snapshots are only recorded when something will
// actually change: a snapshot for a no-op delete makes one Cmd+Z appear to
// do nothing.
@(private = "file")
ti_keys_delete :: proc(ctx: ^TI_Ctx) {
	assert(ctx.sb != nil, "ti_keys_delete: nil builder")
	assert(ctx.sel != nil, "ti_keys_delete: nil selection")
	sb := ctx.sb
	if is_key_pressed(ctx.frame, .BACKSPACE) || is_key_pressed_repeat(ctx.frame, .BACKSPACE) {
		if ti_sel_owner(ctx) {
			// Delete the selected range.
			undo_record(ctx.frame, ctx.undo, sb, ctx.cursor, ctx.pills, .Other)
			nc := selection_delete(ctx.sel, sb, ctx.pills)
			if ctx.caret do ctx.cursor^ = nc
		} else if ctx.caret {
			if ctx.cursor^ > 0 {
				undo_record(ctx.frame, ctx.undo, sb, ctx.cursor, ctx.pills, .Delete)
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
			}
		} else {
			s := strings.to_string(sb^)
			if len(s) > 0 {
				undo_record(ctx.frame, ctx.undo, sb, ctx.cursor, ctx.pills, .Delete)
				// Remove the last whole rune, not the last byte.
				keep := caret_prev_rune(s, len(s))
				strings.builder_reset(sb)
				strings.write_string(sb, s[:keep])
			}
		}
	}
	// Handle forward delete.
	if ctx.caret &&
	   (is_key_pressed(ctx.frame, .DELETE) || is_key_pressed_repeat(ctx.frame, .DELETE)) {
		if ti_sel_owner(ctx) {
			undo_record(ctx.frame, ctx.undo, sb, ctx.cursor, ctx.pills, .Other)
			ctx.cursor^ = selection_delete(ctx.sel, sb, ctx.pills)
		} else if ctx.cursor^ < strings.builder_len(sb^) {
			undo_record(ctx.frame, ctx.undo, sb, ctx.cursor, ctx.pills, .Delete)
			if ctx.pills != nil {
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
				ctx.cursor^ = caret_delete_next(sb, ctx.cursor^)
			}
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
	word := is_key_down(ctx.frame, .LEFT_ALT) || is_key_down(ctx.frame, .RIGHT_ALT)
	moved_vert := false

	if is_key_pressed(ctx.frame, .LEFT) || is_key_pressed_repeat(ctx.frame, .LEFT) {
		if !nav_begin(sel, sb, cursor, shift, true) {
			cursor^ = word ? caret_word_left(s, cursor^) : caret_prev_rune(s, cursor^)
			if ctx.pills != nil do cursor^ = pill_snap_left(ctx.pills, cursor^)
		}
		nav_end(sel, cursor, shift)
	}
	if is_key_pressed(ctx.frame, .RIGHT) || is_key_pressed_repeat(ctx.frame, .RIGHT) {
		if !nav_begin(sel, sb, cursor, shift, false) {
			cursor^ = word ? caret_word_right(s, cursor^) : caret_next_rune(s, cursor^)
			if ctx.pills != nil do cursor^ = pill_snap_right(ctx.pills, cursor^)
		}
		nav_end(sel, cursor, shift)
	}
	if (is_key_pressed(ctx.frame, .UP) || is_key_pressed_repeat(ctx.frame, .UP)) &&
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
	if (is_key_pressed(ctx.frame, .DOWN) || is_key_pressed_repeat(ctx.frame, .DOWN)) &&
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
	mods := mod_down(ctx.frame)
	shift := is_key_down(ctx.frame, .LEFT_SHIFT) || is_key_down(ctx.frame, .RIGHT_SHIFT)
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
	// Shared with text_input_visible_lines so behaviour (Enter semantics)
	// and rendering can never disagree about a box's line count.
	v.visible_lines = text_input_visible_lines(ctx.frame, ctx.h)
	// One star string per frame: the mouse, render, and caret paths all
	// consume the same temp-allocated mask instead of rebuilding it.
	if ctx.masked do v.masked_text = masked_display(text)
	if !v.caret_render do return v
	v.vlines = input_visual_lines_memo_frame(
		ctx.frame,
		ctx.memo,
		text,
		ctx.inner_w,
		metrics.FONT_SIZE_BODY,
	)
	v.cur_vrow, v.cur_caret_x = input_caret_visual_frame(
		ctx.frame,
		v.vlines,
		text,
		ctx.cursor^,
		int(metrics.FONT_SIZE_BODY),
	)
	v.vis_start =
		ctx.scroll_line^ if ctx.scroll_line != nil else max(0, len(v.vlines) - int(v.visible_lines))
	if v.cur_vrow < v.vis_start do v.vis_start = v.cur_vrow
	if v.cur_vrow >= v.vis_start + int(v.visible_lines) {
		v.vis_start = v.cur_vrow - int(v.visible_lines) + 1
	}
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
ti_mouse_masked :: proc(ctx: ^TI_Ctx, text: string, v: ^TI_View) {
	assert(ctx != nil, "ti_mouse_masked: nil ctx")
	assert(ctx.caret, "ti_mouse_masked: caret model required")
	assert(ctx.masked, "ti_mouse_masked: masked input required")
	if !is_mouse_button_pressed(ctx.frame, .LEFT) do return
	mouse := get_mouse_position(ctx.frame)
	if route_occluded(ctx.frame, mouse) do return
	mouse = frame_to_local(ctx.frame, mouse)
	if !point_in_rect(mouse, ctx.rect) do return
	masked_text := v.masked_text
	masked_c := strings.clone_to_cstring(masked_text, context.temp_allocator)
	font_size := ui_frame_metrics(ctx.frame).FONT_SIZE_BODY
	masked_w := measure_text_frame(ctx.frame, masked_c, font_size)
	masked_offset := max(0, masked_w - ctx.inner_w)
	col := caret_pixel_to_col_frame(
		ctx.frame,
		masked_text,
		i32(mouse.x) - ctx.inner_x + masked_offset,
		font_size,
	)
	ctx.cursor^ = caret_col_to_byte(text, col)
	sel_set(ctx.sel, ctx.sb, ctx.cursor^, ctx.cursor^)
}

@(private = "file")
ti_click_count_update :: proc(sel: ^Input_Sel, offset: int, now: f64) {
	assert(sel != nil, "ti_click_count_update: nil selection")
	if now - sel.last_click_time < 0.4 && abs(offset - sel.last_click_byte) <= 2 {
		sel.click_count = min(sel.click_count + 1, 3)
	} else {
		sel.click_count = 1
	}
	sel.last_click_time = now
	sel.last_click_byte = offset
	assert(sel.click_count >= 1 && sel.click_count <= 3, "ti_click_count_update: invalid count")
}

@(private = "file")
ti_click_apply :: proc(ctx: ^TI_Ctx, text: string, offset: int) {
	assert(ctx != nil && ctx.sel != nil, "ti_click_apply: invalid context")
	assert(offset >= 0 && offset <= len(text), "ti_click_apply: invalid offset")
	sel := ctx.sel
	switch sel.click_count {
	case 2:
		start, end := find_word_bounds(text, offset)
		sel_set(sel, ctx.sb, start, end)
		sel.dragging = true
		ctx.cursor^ = end
	case 3:
		start := caret_line_start(text, offset)
		end := caret_line_end(text, offset)
		sel_set(sel, ctx.sb, start, end)
		sel.dragging = false
		ctx.cursor^ = end
	case:
		ctx.cursor^ = offset
		if ctx.pills != nil do ctx.cursor^ = pill_snap_caret(ctx.pills, ctx.cursor^)
		sel_set(sel, ctx.sb, ctx.cursor^, ctx.cursor^)
		sel.dragging = true
	}
	assert(ctx.cursor^ >= 0 && ctx.cursor^ <= len(text), "ti_click_apply: invalid cursor")
}

// ti_mouse_caret handles press (single/double/triple click), drag-extend, and
// release for the caret-aware renderer, then refreshes the caret's visual
// position so highlight and caret don't lag one frame.
@(private = "file")
ti_mouse_caret :: proc(ctx: ^TI_Ctx, text: string, v: ^TI_View) {
	assert(ctx.caret, "ti_mouse_caret: caret model required")
	assert(v.caret_render, "ti_mouse_caret: caret renderer required")
	sel := ctx.sel
	mouse := get_mouse_position(ctx.frame)
	occluded := route_occluded(ctx.frame, mouse)
	mouse = frame_to_local(ctx.frame, mouse)
	moved := false
	if is_mouse_button_pressed(ctx.frame, .LEFT) && !occluded {
		if point_in_rect(mouse, ctx.rect) {
			off := input_mouse_to_byte(
				ctx.frame,
				v.vlines,
				text,
				mouse,
				ctx.inner_x,
				ctx.y,
				v.vis_start,
				v.vis_end,
			)
			ti_click_count_update(sel, off, frame_input(ctx.frame).time)
			ti_click_apply(ctx, text, off)
			moved = true
			if ctx.desired_col != nil {
				_, c := caret_row_col(text, ctx.cursor^)
				ctx.desired_col^ = c
			}
		} else if sel.sb == ctx.sb {
			sel_reset(sel)
		}
	}
	if sel.dragging && sel.sb == ctx.sb && is_mouse_button_down(ctx.frame, .LEFT) {
		off := input_mouse_to_byte(
			ctx.frame,
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
			moved = true
		}
	}
	if sel.dragging && is_mouse_button_released(ctx.frame, .LEFT) {
		sel.dragging = false
		if sel.anchor == sel.extent do sel.active = false
	}
	// ti_layout already computed the caret's visual position this frame;
	// recompute only when a click or drag actually moved it, so idle frames
	// skip the second prefix measure.
	if moved {
		v.cur_vrow, v.cur_caret_x = input_caret_visual_frame(
			ctx.frame,
			v.vlines,
			text,
			ctx.cursor^,
			int(ui_frame_metrics(ctx.frame).FONT_SIZE_BODY),
		)
	}
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
	if is_mouse_button_pressed(ctx.frame, .RIGHT) {
		mouse := get_mouse_position(ctx.frame)
		occluded := route_occluded(ctx.frame, mouse)
		mouse = frame_to_local(ctx.frame, mouse)
		if !occluded && point_in_rect(mouse, ctx.rect) {
			off := input_mouse_to_byte(
				ctx.frame,
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
				_, word_x := input_caret_visual_frame(
					ctx.frame,
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

// TI_Span_Px is one byte-range's resolved geometry on a visual line.
@(private = "file")
TI_Span_Px :: struct {
	seg: cstring,
	x:   i32,
	w:   i32,
}

// ti_line_span_px measures the overlap of [lo,hi) with visual line `vl`
// once, so the chip background, accent text, and squiggle passes reuse one
// geometry instead of re-measuring the same prefixes per pass.
@(private = "file")
ti_line_span_px :: proc(
	ctx: ^TI_Ctx,
	text: string,
	vl: Wrap_Line,
	lo, hi: int,
	font_size: i32,
) -> (
	span: TI_Span_Px,
	ok: bool,
) {
	assert(ctx != nil, "ti_line_span_px: nil ctx")
	assert(vl.start <= vl.end && vl.end <= len(text), "ti_line_span_px: bad line")
	assert(lo <= hi, "ti_line_span_px: inverted span")
	s := max(lo, vl.start)
	e := min(hi, vl.end)
	if s >= e do return {}, false
	pre_c := strings.clone_to_cstring(text[vl.start:s], context.temp_allocator)
	span.seg = strings.clone_to_cstring(text[s:e], context.temp_allocator)
	span.x = ctx.inner_x + measure_text_frame(ctx.frame, pre_c, font_size)
	span.w = measure_text_frame(ctx.frame, span.seg, font_size)
	return span, true
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
		line_c := strings.clone_to_cstring(text[vl.start:vl.end], context.temp_allocator)
		line_y := ctx.y + ui_frame_sc(ctx.frame, TI_PAD_TOP) + render_idx * line_height
		// Selection highlight: overlap of this visual line with the range.
		if sel.active && sel.sb == ctx.sb {
			lo, hi := sel_range(sel)
			if hl, hl_ok := ti_line_span_px(ctx, text, vl, lo, hi, font_size); hl_ok {
				draw_rectangle(ctx.frame, hl.x, line_y, hl.w, font_size, style.bg_selection)
			}
		}
		// Pill spans are measured once and reused for the chip background and
		// the accent redraw (previously two identical measure passes).
		pill_spans := make([dynamic]TI_Span_Px, context.temp_allocator)
		if ctx.pills != nil {
			for p in ctx.pills {
				if span, p_ok := ti_line_span_px(ctx, text, vl, p.start, p.end, font_size); p_ok {
					append(&pill_spans, span)
				}
			}
		}
		for span in pill_spans {
			draw_input_pill_bg_frame(ctx.frame, span.x, line_y, span.w)
		}
		draw_text_frame(ctx.frame, line_c, ctx.inner_x, line_y, font_size, style.fg_primary)
		for span in pill_spans {
			draw_text_frame(ctx.frame, span.seg, span.x, line_y, font_size, style.fg_accent)
		}
		// Red squiggles under misspelled words on this visual line.
		for r in squiggles {
			if span, s_ok := ti_line_span_px(ctx, text, vl, r.start, r.end, font_size); s_ok {
				draw_squiggle(
					ctx.frame,
					span.x,
					line_y + font_size + ui_frame_sc(ctx.frame, 1),
					span.w,
					style.spell_error,
				)
			}
		}
		render_idx += 1
	}
}

// ti_render_multiline draws newline-split lines showing the bottom of the
// text (legacy non-caret path; cursor is always at the end).
@(private = "file")
ti_render_multiline :: proc(ctx: ^TI_Ctx, text: string, v: ^TI_View, sel_all: bool) {
	assert(ctx != nil, "ti_render_multiline: nil ctx")
	assert(v != nil, "ti_render_multiline: nil v")
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
		line_y := ctx.y + ui_frame_sc(ctx.frame, TI_PAD_TOP) + render_idx * line_height
		// Only the last line gets horizontal scrolling (cursor is at the end).
		if i == i32(len(lines)) - 1 {
			line_pixel_w := measure_text_frame(ctx.frame, line_c, font_size)
			line_offset: i32 = 0
			if line_pixel_w > ctx.inner_w {
				line_offset = line_pixel_w - ctx.inner_w
			}
			if sel_all {
				hl_w := min(line_pixel_w, ctx.inner_w)
				draw_rectangle(ctx.frame, ctx.inner_x, line_y, hl_w, font_size, style.bg_selection)
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
				draw_rectangle(ctx.frame, ctx.inner_x, line_y, hl_w, font_size, style.bg_selection)
			}
			draw_text_frame(ctx.frame, line_c, ctx.inner_x, line_y, font_size, style.fg_primary)
		}
		render_idx += 1
	}
}

// ti_render_single draws the single-line (optionally masked) path with
// horizontal end-scroll.
@(private = "file")
ti_render_single :: proc(ctx: ^TI_Ctx, text: string, v: ^TI_View, sel_all: bool) {
	assert(ctx != nil, "ti_render_single: nil ctx")
	assert(len(text) > 0, "ti_render_single: empty text")
	assert(ctx.inner_w >= 0, "ti_render_single: negative inner width")
	metrics := ui_frame_metrics(ctx.frame)
	style := ui_frame_theme(ctx.frame)
	font_size := metrics.FONT_SIZE_BODY
	display_text := v.masked_text if ctx.masked else text
	display_c := strings.clone_to_cstring(display_text, context.temp_allocator)
	text_pixel_w := measure_text_frame(ctx.frame, display_c, font_size)
	text_offset: i32 = 0
	if text_pixel_w > ctx.inner_w {
		text_offset = text_pixel_w - ctx.inner_w
	}
	if sel_all {
		hl_w := min(text_pixel_w, ctx.inner_w)
		draw_rectangle(
			ctx.frame,
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
	assert(ctx != nil, "ti_draw_caret: nil ctx")
	assert(v != nil, "ti_draw_caret: nil v")
	assert(ctx.active, "ti_draw_caret: input not active")
	assert(ctx.h > 0, "ti_draw_caret: non-positive height")
	metrics := ui_frame_metrics(ctx.frame)
	style := ui_frame_theme(ctx.frame)
	font_size := metrics.FONT_SIZE_BODY
	line_height := metrics.LINE_HEIGHT
	t := frame_input(ctx.frame).time
	blink_on := true
	if !style.reduced_motion {
		// Blink is time-driven: in event-driven frame mode nothing else
		// forces a repaint while the user pauses typing, so schedule one at
		// the next half-second toggle boundary. Reduced motion keeps the
		// caret steady (no blink, no scheduled repaints).
		request_redraw_in(ctx.frame, 0.5 - math.mod(t, 0.5))
		blink_on = int(t * 2) % 2 == 0
	}
	if v.caret_render {
		// Caret at its true visual (row, x) within the visible window.
		if v.cur_vrow >= v.vis_start && v.cur_vrow < v.vis_end {
			cursor_x := ctx.inner_x + v.cur_caret_x
			cursor_line_y :=
				ctx.y +
				ui_frame_sc(ctx.frame, TI_PAD_TOP) +
				i32(v.cur_vrow - v.vis_start) * line_height
			set_text_input_rect(ctx.frame, cursor_x, cursor_line_y, 1, font_size)
			if blink_on {
				draw_line(
					ctx.frame,
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
		cursor_line_y :=
			ctx.y + ui_frame_sc(ctx.frame, TI_PAD_TOP) + (visible_count - 1) * line_height
		set_text_input_rect(ctx.frame, cursor_x, cursor_line_y, 1, font_size)
		if blink_on {
			draw_line(
				ctx.frame,
				cursor_x,
				cursor_line_y,
				cursor_x,
				cursor_line_y + font_size,
				style.fg_accent,
			)
		}
		return
	}
	ti_draw_caret_single(ctx, text, v, blink_on)
}

// ti_draw_caret_single draws the caret for the single-line render path,
// mapping the byte cursor through the (possibly masked) display string.
@(private = "file")
ti_draw_caret_single :: proc(ctx: ^TI_Ctx, text: string, v: ^TI_View, blink_on: bool) {
	assert(ctx != nil, "ti_draw_caret_single: nil ctx")
	assert(ctx.active, "ti_draw_caret_single: input not active")
	assert(ctx.h > 0, "ti_draw_caret_single: non-positive height")
	font_size := ui_frame_metrics(ctx.frame).FONT_SIZE_BODY
	style := ui_frame_theme(ctx.frame)
	display_for_cursor := v.masked_text if ctx.masked else text
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
	// The IME rect and the drawn caret share one scaled inset, or the
	// candidate window drifts from the caret at UI scales other than 1.
	inset := ui_frame_sc(ctx.frame, TI_CARET_INSET)
	set_text_input_rect(ctx.frame, cursor_x, ctx.y + inset, 1, ctx.h - inset * 2)
	if blink_on {
		draw_line(
			ctx.frame,
			cursor_x,
			ctx.y + inset,
			cursor_x,
			ctx.y + ctx.h - inset,
			style.fg_accent,
		)
	}
}

@(private = "file")
ti_draw_chrome :: proc(ctx: ^TI_Ctx) {
	assert(ctx != nil, "ti_draw_chrome: nil context")
	assert(ctx.frame != nil, "ti_draw_chrome: nil frame")
	style := ui_frame_theme(ctx.frame)
	bg := style.bg_input if ctx.active else style.bg_secondary
	draw_rectangle_rec(ctx.frame, ctx.rect, bg)
	draw_rectangle_lines_ex(
		ctx.frame,
		ctx.rect,
		ui_frame_scf(ctx.frame, 1),
		style.border_color if !ctx.active else style.fg_accent,
	)
}

@(private = "file")
ti_selection_is_all :: proc(ctx: ^TI_Ctx, text_length: int) -> bool {
	assert(ctx != nil, "ti_selection_is_all: nil context")
	assert(text_length >= 0, "ti_selection_is_all: negative text length")
	sel := ctx.sel
	return(
		sel.active &&
		sel.sb == ctx.sb &&
		min(sel.anchor, sel.extent) == 0 &&
		max(sel.anchor, sel.extent) == text_length \
	)
}

@(private = "file")
ti_render_content :: proc(
	ctx: ^TI_Ctx,
	text: string,
	view: ^TI_View,
	spell_squiggles: []Spell_Range,
) {
	assert(ctx != nil, "ti_render_content: nil context")
	assert(view != nil, "ti_render_content: nil view")
	font_size := ui_frame_metrics(ctx.frame).FONT_SIZE_BODY
	if len(text) == 0 {
		placeholder := strings.clone_to_cstring(ctx.placeholder, context.temp_allocator)
		draw_text_frame(
			ctx.frame,
			placeholder,
			ctx.inner_x,
			ctx.y + (ctx.h - font_size) / 2,
			font_size,
			ui_frame_theme(ctx.frame).fg_secondary,
		)
	} else if view.caret_render {
		ti_render_caret_lines(ctx, text, view, spell_squiggles)
	} else if view.has_newlines {
		ti_render_multiline(ctx, text, view, ti_selection_is_all(ctx, len(text)))
	} else {
		ti_render_single(ctx, text, view, ti_selection_is_all(ctx, len(text)))
	}
}

@(private = "file")
ti_draw_clipped :: proc(ctx: ^TI_Ctx) {
	assert(ctx.inner_w > 0, "ti_draw_clipped: non-positive inner width")
	assert(ctx.h > 0, "ti_draw_clipped: non-positive height")
	begin_pane_scissor(ctx.frame, ctx.inner_x, ctx.y, ctx.inner_w, ctx.h)
	text := strings.to_string(ctx.sb^)
	view := ti_layout(ctx, text)
	if ctx.active && view.masked_caret do ti_mouse_masked(ctx, text, &view)
	if ctx.active && view.caret_render do ti_mouse_caret(ctx, text, &view)
	spell_squiggles: []Spell_Range
	if ctx.active && view.caret_render && ctx.pills != nil && ctx.undo != nil {
		spell_squiggles = ti_spell(ctx, text, &view)
	}
	ti_render_content(ctx, text, &view, spell_squiggles)
	if ctx.active do ti_draw_caret(ctx, text, &view)
	end_scissor_mode(ctx.frame)
}

@(private = "file")
ti_draw_spell_popup :: proc(ctx: ^TI_Ctx) {
	assert(ctx != nil, "ti_draw_spell_popup: nil context")
	if spell_menu_active(ctx.spell_menu, ctx.sb) {
		draw_spell_menu(ctx.frame, ctx.spell_menu, ui_frame_spell(ctx.frame), ctx.x, ctx.y, ctx.w)
	}
}

@(private = "file")
ti_inactive_candidate :: proc(ctx: ^TI_Ctx) -> bool {
	assert(ctx != nil && ctx.sb != nil, "ti_inactive_candidate: invalid context")
	assert(ctx.sel != nil && ctx.spell_menu != nil, "ti_inactive_candidate: missing state")
	text := strings.to_string(ctx.sb^)
	return(
		!ctx.active &&
		!ctx.masked &&
		!strings.contains_rune(text, '\n') &&
		!ctx.sel.active &&
		(ctx.pills == nil || len(ctx.pills) == 0) &&
		!spell_menu_active(ctx.spell_menu, ctx.sb) \
	)
}

// ti_run drives one frame of the input and reports whether Enter submitted it.
@(private = "file")
ti_run :: proc(ctx: ^TI_Ctx) -> bool {
	assert(ctx.sb != nil, "ti_run: nil builder")
	assert(ctx.sel != nil && ctx.memo != nil, "ti_run: nil selection or memo")
	when UI_TELEMETRY_ENABLED {
		ctx.frame.text_input_full_path_count += 1
		if ti_inactive_candidate(ctx) do ctx.frame.text_input_inactive_candidates += 1
	}
	ti_sync_web(ctx)
	ti_semantic_push(ctx)
	ti_draw_chrome(ctx)
	entered := false
	if ctx.active do entered = ti_keys(ctx)
	ti_draw_clipped(ctx)
	ti_draw_spell_popup(ctx)
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
	metrics := ui_frame_metrics(frame)
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
		rect        = Rectangle {
			f32(cfg.rect.x),
			f32(cfg.rect.y),
			f32(cfg.rect.w),
			f32(cfg.rect.h),
		},
		inner_x     = cfg.rect.x + metrics.PADDING,
		inner_w     = cfg.rect.w - metrics.PADDING * 2,
		placeholder = cfg.placeholder,
		masked      = cfg.masked,
		max_bytes   = cfg.max_bytes if cfg.max_bytes > 0 else INPUT_MAX_LEN,
		single_line = cfg.single_line,
		submit      = cfg.submit,
		filter      = cfg.filter,
		semantics   = cfg.semantics,
		active      = cfg.active,
		caret       = true,
	}
	assert(ctx.max_bytes > 0 && ctx.max_bytes <= INPUT_MAX_LEN, "text_input_box: invalid max")
	return ti_run(&ctx)
}

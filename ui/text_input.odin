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

import "core:strings"

// Vertical padding above the first text line inside the box. Mouse
// hit-testing and rendering must resolve this through one shared constant
// (scaled per frame) or clicks map to the wrong row at UI scales other
// than 1.
@(private)
TI_PAD_TOP :: 6
// Total vertical padding (top + bottom) a box spends around its text; the
// visible line count is derived from the height that remains.
@(private)
TI_PAD_VERT :: TI_PAD_TOP * 2
// Inset of the single-line caret (and its IME rect) from the box edges.
@(private)
TI_CARET_INSET :: 5
// Minimum seconds between drag auto-scroll row steps while the mouse is held
// outside the box's vertical band. Bounds the scroll rate independently of
// the frame rate (one row per tick, never more).
@(private)
TI_DRAG_SCROLL_SECS :: 0.05


// Range selection for a text input. `anchor` is where the selection started
// (mouse press / shift origin) and `extent` is the moving end; both are byte
// offsets into the owning builder and may be in either order.
Input_Sel :: struct {
	sb:               ^strings.Builder,
	anchor:           int,
	extent:           int,
	active:           bool,
	dragging:         bool,
	last_click_time:  f64,
	last_click_byte:  int,
	click_count:      int,
	drag_scroll_time: f64,
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
	desired_x:   i32, // preserved caret x (px) for visual-row Up/Down
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
@(private)
TI_Ctx :: struct {
	frame:       ^Ui_Frame,
	sb:          ^strings.Builder,
	cursor:      ^int, // nil = end-anchored legacy input (no caret model)
	desired_col: ^int,
	desired_x:   ^i32,
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
@(private)
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
	// IME preedit byte range within the display text (lo == hi when not
	// composing). The renderer underlines it and shifts committed-text
	// spans (selection, pills) that sit at or after the insertion point.
	preedit_lo:    int,
	preedit_hi:    int,
}

@(private)
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
	// While an OS input method is composing, it owns the keyboard: nav,
	// delete, and shortcuts must not fire mid-composition. Committed text
	// still arrives through the character queue once composition ends.
	preedit, _ := frame_preedit(ctx.frame)
	composing := ctx.caret && !ctx.masked && len(preedit) > 0
	if ctx.active && !composing do entered = ti_keys(ctx)
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
		desired_x   = &st.desired_x,
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

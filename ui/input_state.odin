// LIB-CANDIDATE: imports only core:*.
// Ergonomic state bundling for text inputs: one caller-owned struct instead
// of a builder plus a state struct at every call site. Nothing here is
// library-retained — the bundle lives in the caller's data, and `input` is a
// thin wrapper over text_input_box.
package ui

import "core:strings"

// Input_Box owns its builder, undo snapshots, pills, and wrap memo. The zero
// value is ready to use. Do not copy it after first use; destroy it before its
// owner is discarded.
Input_Box :: struct {
	sb: strings.Builder,
	st: Text_Input_State,
}

// input_box_init prepares a bundle (optional — the zero value works; init
// exists for symmetry with destroy and for arena-backed builders).
input_box_init :: proc(b: ^Input_Box, allocator := context.allocator) {
	assert(b != nil, "input_box_init: nil box")
	b.sb = strings.builder_make(allocator)
	b.st = {}
}

// input_box_destroy releases all heap state owned by the bundle.
input_box_destroy :: proc(b: ^Input_Box) {
	assert(b != nil, "input_box_destroy: nil box")
	strings.builder_destroy(&b.sb)
	text_input_state_destroy(&b.st)
	assert(strings.builder_len(b.sb) == 0, "input_box_destroy: builder not cleared")
}

// input_box_reset clears the text and interaction state but keeps allocated
// capacity (builder buffer, undo stacks' backing arrays).
input_box_reset :: proc(b: ^Input_Box) {
	assert(b != nil, "input_box_reset: nil box")
	strings.builder_reset(&b.sb)
	b.st.cursor = 0
	b.st.desired_col = 0
	b.st.scroll_line = 0
	sel_reset(&b.st.sel)
	input_undo_reset(&b.st.undo)
	clear(&b.st.pills)
	input_vlines_memo_destroy(&b.st.memo)
	spellcheck_memo_destroy(&b.st.spell_memo)
	assert(!b.st.sel.active && b.st.cursor == 0, "input_box_reset: state not cleared")
}

// input_box_text returns a borrowed view valid until the box is mutated or destroyed.
input_box_text :: proc(b: ^Input_Box) -> string {
	assert(b != nil, "input_box_text: nil box")
	return strings.to_string(b.sb)
}

input_box_text_clone :: proc(b: ^Input_Box, allocator := context.allocator) -> string {
	assert(b != nil, "input_box_text_clone: nil box")
	return strings.clone(input_box_text(b), allocator)
}

Input_Box_Group :: struct {
	items: []Input_Box,
}

input_box_group_init :: proc(group: ^Input_Box_Group, items: []Input_Box) {
	assert(group != nil, "input_box_group_init: nil group")
	assert(group.items == nil, "input_box_group_init: already initialized")
	group.items = items
}

input_box_group_reset :: proc(group: ^Input_Box_Group) {
	assert(group != nil, "input_box_group_reset: nil group")
	for &item in group.items do input_box_reset(&item)
}

input_box_group_destroy :: proc(group: ^Input_Box_Group) {
	assert(group != nil, "input_box_group_destroy: nil group")
	for &item in group.items do input_box_destroy(&item)
	group^ = {}
}

// input_box_set_text replaces the text and parks the caret at the end.
//
// Why it exists: an immediate-mode form is rendered from application state, so
// loading a record, resetting a form, or restoring a draft all need to push text
// into the bundle. Without a setter callers reached into the builder directly
// and left cursor, selection, undo, and the wrap memo describing the old text.
//
// The edit is not undoable on purpose: it is a programmatic reload, not a user
// edit, so folding it into the undo stack would let ctrl+z resurrect another
// record's text.
input_box_set_text :: proc(b: ^Input_Box, text: string) {
	assert(b != nil, "input_box_set_text: nil box")
	input_box_reset(b)
	strings.write_string(&b.sb, text)
	b.st.cursor = strings.builder_len(b.sb)
	assert(b.st.cursor == len(text), "input_box_set_text: caret not at end of text")
	assert(!b.st.sel.active, "input_box_set_text: stale selection survived")
}

input_box_selecting :: proc(b: ^Input_Box) -> bool {
	assert(b != nil, "input_box_selecting: nil box")
	return text_input_selecting(&b.st)
}

input_box_selection_range :: proc(b: ^Input_Box) -> (lo, hi: int) {
	assert(b != nil, "input_box_selection_range: nil box")
	return text_input_selection_range(&b.st)
}

input_box_selection_set :: proc(b: ^Input_Box, anchor, extent: int) {
	assert(b != nil, "input_box_selection_set: nil box")
	text_input_selection_set(&b.st, &b.sb, anchor, extent)
}

input_box_selection_clear :: proc(b: ^Input_Box) {
	assert(b != nil, "input_box_selection_clear: nil box")
	text_input_selection_clear(&b.st)
}

Text_Input_Options :: struct {
	height:    i32,
	masked:    bool,
	semantics: Text_Input_Semantics,
}

Text_Input_At_Options :: struct {
	active:    bool,
	masked:    bool,
	semantics: Text_Input_Semantics,
}

// input draws a caret-aware text input backed by an Input_Box, with pills and
// undo enabled. Same call-site brevity as an immediate-mode one-liner while
// every byte of state stays caller-owned. Returns true when Enter submitted.
// text_input carves a full-width slot; text_input_at takes an explicit rect.
@(private = "package")
text_input_id :: proc(
	u: ^Ui,
	id: Widget_Id,
	b: ^Input_Box,
	placeholder: string,
	height: i32 = 0,
	masked: bool = false,
	semantics: Text_Input_Semantics = {},
) -> bool {
	assert(u != nil && u.open, "text_input: frame not open")
	assert(id != WIDGET_ID_NONE, "text_input: zero stable id")
	assert(b != nil, "text_input: nil box")
	assert(semantics.name != "", "text_input: empty accessible label")
	metrics := ui_frame_metrics(u.frame)
	resolved_height :=
		ui_frame_sc(u.frame, height) if height > 0 else metrics.ROW_H_MD + metrics.CONTROL_GAP
	r := slot_next_px(u, remaining(&u.layout).w, resolved_height)
	fo := focus(u, id) if slot_visible(r) else Focus_Opt{}
	focus_opt_click(u.frame, fo, r.x, r.y, r.w, r.h)
	sem := semantics
	sem.focus = fo.focus
	sem.focus_id = fo.id
	sem.widget = id
	return text_input_at(u.frame, r, b, placeholder, focus_opt_focused(fo), masked, sem)
}

@(private = "package")
text_input_string :: proc(
	u: ^Ui,
	key: string,
	b: ^Input_Box,
	placeholder: string,
	height: i32 = 0,
	masked: bool = false,
	semantics: Text_Input_Semantics = {},
) -> bool {
	assert(u != nil && b != nil, "text_input: nil UI or box")
	return text_input_id(u, id(u, key), b, placeholder, height, masked, semantics)
}

@(private = "package")
text_input_u64 :: proc(
	u: ^Ui,
	key: u64,
	b: ^Input_Box,
	placeholder: string,
	height: i32 = 0,
	masked: bool = false,
	semantics: Text_Input_Semantics = {},
) -> bool {
	assert(u != nil && b != nil, "text_input: nil UI or box")
	return text_input_id(u, id(u, key), b, placeholder, height, masked, semantics)
}

@(private = "package")
text_input_id_options :: proc(
	u: ^Ui,
	id: Widget_Id,
	b: ^Input_Box,
	placeholder: string,
	options: Text_Input_Options,
) -> bool {
	return text_input_id(u, id, b, placeholder, options.height, options.masked, options.semantics)
}

@(private = "package")
text_input_string_options :: proc(
	u: ^Ui,
	key: string,
	b: ^Input_Box,
	placeholder: string,
	options: Text_Input_Options,
) -> bool {
	return text_input_id_options(u, id(u, key), b, placeholder, options)
}

@(private = "package")
text_input_u64_options :: proc(
	u: ^Ui,
	key: u64,
	b: ^Input_Box,
	placeholder: string,
	options: Text_Input_Options,
) -> bool {
	return text_input_id_options(u, id(u, key), b, placeholder, options)
}

text_input :: proc {
	text_input_id,
	text_input_string,
	text_input_u64,
	text_input_id_options,
	text_input_string_options,
	text_input_u64_options,
}

text_input_at :: proc(
	frame: ^Ui_Frame,
	rect: Rect_I32,
	b: ^Input_Box,
	placeholder: string,
	active: bool,
	masked: bool = false,
	semantics: Text_Input_Semantics = {},
) -> bool {
	assert(frame != nil, "text_input_at: nil frame")
	assert(b != nil, "text_input_at: nil box")
	if ui_frame_drop_degenerate(frame, rect.w <= 0 || rect.h <= 0) do return false
	cfg := Text_Input_Config {
		rect         = rect,
		placeholder  = placeholder,
		active       = active,
		masked       = masked,
		enable_pills = true,
		enable_undo  = true,
		semantics    = semantics,
	}
	return text_input_box(frame, cfg, &b.sb, &b.st)
}

text_input_with_options_at :: proc(
	frame: ^Ui_Frame,
	rect: Rect_I32,
	b: ^Input_Box,
	placeholder: string,
	options: Text_Input_At_Options,
) -> bool {
	assert(frame != nil && b != nil, "text_input_at: nil frame or box")
	return text_input_at(
		frame,
		rect,
		b,
		placeholder,
		options.active,
		options.masked,
		options.semantics,
	)
}

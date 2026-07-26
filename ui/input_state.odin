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

// input_box_text returns the current text (a view into the builder).
input_box_text :: proc(b: ^Input_Box) -> string {
	assert(b != nil, "input_box_text: nil box")
	return strings.to_string(b.sb)
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

// input draws a caret-aware text input backed by an Input_Box, with pills and
// undo enabled. Same call-site brevity as an immediate-mode one-liner while
// every byte of state stays caller-owned. Returns true when Enter submitted.
input :: proc {
	input_at,
	input_ui,
	input_ui_id,
}

// input_ui carves a full-width slot (height h, 0 = single-line default),
// acquires focus on click, and is active while it owns the Ui focus slot.
input_ui :: proc(
	u: ^Ui,
	b: ^Input_Box,
	placeholder: string,
	h: i32 = 0,
	masked: bool = false,
	semantics: Text_Input_Semantics = {},
) -> bool {
	assert(semantics.name != "", "input_ui: empty accessible label")
	metrics := ui_frame_metrics(u.frame)
	hh := h if h > 0 else metrics.ROW_H_MD + metrics.CONTROL_GAP
	r := ui_slot(u, remaining(&u.layout).w, hh)
	fo := ui_focus(u) if ui_slot_visible(r) else Focus_Opt{}
	focus_opt_click(u.frame, fo, r.x, r.y, r.w, r.h)
	sem := semantics
	sem.focus = fo.focus
	sem.focus_id = fo.id
	return input_at(
		u.frame,
		r.x,
		r.y,
		r.w,
		r.h,
		b,
		placeholder,
		focus_opt_focused(fo),
		masked,
		sem,
	)
}

input_ui_id :: proc(
	u: ^Ui,
	id: Widget_Id,
	b: ^Input_Box,
	placeholder: string,
	h: i32 = 0,
	masked: bool = false,
	semantics: Text_Input_Semantics = {},
) -> bool {
	assert(semantics.name != "", "input_ui_id: empty accessible label")
	metrics := ui_frame_metrics(u.frame)
	hh := h if h > 0 else metrics.ROW_H_MD + metrics.CONTROL_GAP
	r := ui_slot(u, remaining(&u.layout).w, hh)
	fo := ui_focus(u, id) if ui_slot_visible(r) else Focus_Opt{}
	focus_opt_click(u.frame, fo, r.x, r.y, r.w, r.h)
	sem := semantics
	sem.focus = fo.focus
	sem.focus_id = fo.id
	sem.widget = id
	return input_at(
		u.frame,
		r.x,
		r.y,
		r.w,
		r.h,
		b,
		placeholder,
		focus_opt_focused(fo),
		masked,
		sem,
	)
}

input_at :: proc(
	frame: ^Ui_Frame,
	x, y, w, h: i32,
	b: ^Input_Box,
	placeholder: string,
	active: bool,
	masked: bool = false,
	semantics: Text_Input_Semantics = {},
) -> bool {
	assert(b != nil, "input: nil box")
	if ui_frame_drop_degenerate(frame, w <= 0 || h <= 0) do return false
	cfg := Text_Input_Config {
		rect         = Rect_I32{x, y, w, h},
		placeholder  = placeholder,
		active       = active,
		masked       = masked,
		enable_pills = true,
		enable_undo  = true,
		semantics    = semantics,
	}
	return text_input_box(frame, cfg, &b.sb, &b.st)
}

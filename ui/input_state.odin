// LIB-CANDIDATE: imports only core:* and ingot:gfx.
// Ergonomic state bundling for text inputs: one caller-owned struct instead
// of a builder plus a state struct at every call site. Nothing here is
// library-retained — the bundle lives in the caller's data, and `input` is a
// thin wrapper over text_input_box.
package ui

import "core:strings"

// Input_Box bundles everything one text input persists across frames. The
// zero value is ready to use; call input_box_destroy when done.
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
}

// input_box_text returns the current text (a view into the builder).
input_box_text :: proc(b: ^Input_Box) -> string {
	assert(b != nil, "input_box_text: nil box")
	return strings.to_string(b.sb)
}

// input draws a caret-aware text input backed by an Input_Box, with pills and
// undo enabled. Same call-site brevity as an immediate-mode one-liner while
// every byte of state stays caller-owned. Returns true when Enter submitted.
input :: proc {
	input_at,
	input_ui,
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
	fo := ui_focus(u)
	hh := h if h > 0 else ROW_H_MD + CONTROL_GAP
	r := ui_slot(u, remaining(&u.layout).w, hh)
	focus_opt_click(fo, r.x, r.y, r.w, r.h)
	return input_at(r.x, r.y, r.w, r.h, b, placeholder, focus_opt_focused(fo), masked, semantics)
}

input_at :: proc(
	x, y, w, h: i32,
	b: ^Input_Box,
	placeholder: string,
	active: bool,
	masked: bool = false,
	semantics: Text_Input_Semantics = {},
) -> bool {
	assert(b != nil, "input: nil box")
	assert(w > 0 && h > 0, "input: empty rect")
	cfg := Text_Input_Config {
		rect         = Rect_I32{x, y, w, h},
		placeholder  = placeholder,
		active       = active,
		masked       = masked,
		enable_pills = true,
		enable_undo  = true,
		semantics    = semantics,
	}
	return text_input_box(cfg, &b.sb, &b.st)
}

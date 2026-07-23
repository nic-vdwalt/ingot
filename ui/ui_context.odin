// LIB-CANDIDATE: imports only core:* and ingot:gfx.
// Ui is a caller-owned context bundling the cursor Layout, a keyboard-focus
// slot with automatic sequential ids, and cached screen size. Widgets with a
// ^Ui variant carve their own rect and register for Tab focus, removing the
// manual rect math and 1-based hand-numbering the rect API requires.
// Immediate-mode contract holds: the caller declares the Ui, owns it, and
// passes it each frame. No hashing, no hidden storage: a widget's focus id is
// simply its registration order this frame. Consequence: if the set of
// focusable widgets changes between frames, focus can land on a neighbour for
// one frame — the same failure mode as hand-numbered ids.
package ui

import "core:strings"
import rl "ingot:gfx"

// MAX_FOCUSABLES bounds focus registrations per frame (Tiger Style: put a
// limit on everything).
MAX_FOCUSABLES :: 256

// Ui is caller-owned. focus_slot/focus_count persist across frames; the rest
// is per-frame scratch reset by ui_begin.
Ui :: struct {
	layout:      Layout,
	focus_slot:  int, // 0 = nothing focused; ids are 1-based
	focus_count: int, // focusables registered last frame (Tab cycle bound)
	focus_seq:   int, // per-frame registration counter
	screen_w:    i32,
	screen_h:    i32,
	open:        bool,
}

// ui_begin opens the frame over the given area: caches screen size, runs Tab
// cycling against last frame's focusable count, and opens the root column.
ui_begin :: proc(u: ^Ui, x, y, w, h: i32, gap: i32 = 0) {
	assert(u != nil, "ui_begin: nil Ui")
	assert(!u.open, "ui_begin: frame already open")
	u.screen_w = rl.GetScreenWidth()
	u.screen_h = rl.GetScreenHeight()
	// One-frame latency on count, same double-buffer idea as route claims
	// (input_route.odin): last frame's registrations bound this frame's Tab.
	if u.focus_count > 0 {
		form_focus_cycle(&u.focus_slot, u.focus_count)
	}
	u.focus_seq = 0
	layout_begin(&u.layout, x, y, w, h, gap)
	u.open = true
}

// ui_end closes the root layout and latches the focusable count.
ui_end :: proc(u: ^Ui) {
	assert(u.open, "ui_end: frame not open")
	layout_end(&u.layout)
	u.focus_count = u.focus_seq
	u.open = false
}

// ui_focus registers the next focusable widget and returns its Focus_Opt.
// Deterministic: id = registration order this frame (1-based).
ui_focus :: proc(u: ^Ui) -> Focus_Opt {
	assert(u.open, "ui_focus: frame not open")
	assert(u.focus_seq < MAX_FOCUSABLES, "ui_focus: too many focusables")
	u.focus_seq += 1
	return Focus_Opt{&u.focus_slot, u.focus_seq}
}

// ui_slot carves a w×h rect from the active layout frame. In a column the
// main axis is h (cross trimmed to w); in a row it is w (cross trimmed to h).
ui_slot :: proc(u: ^Ui, w, h: i32) -> Rect_I32 {
	assert(u.open, "ui_slot: frame not open")
	assert(w >= 0 && h >= 0, "ui_slot: negative size")
	l := &u.layout
	if layout_kind(l) == .Column {
		r := next(l, h)
		r.w = min(r.w, w)
		return r
	}
	r := next(l, w)
	r.h = min(r.h, h)
	return r
}

// ui_flex_begin resolves sibling main-axis sizes on the active Ui frame.
ui_flex_begin :: proc(u: ^Ui, sizes: []Flex_Size) {
	assert(u != nil, "ui_flex_begin: nil Ui")
	assert(u.open, "ui_flex_begin: frame not open")
	flex_begin(&u.layout, sizes)
}

// ui_flex_slot consumes one flex size and trims only the cross axis.
ui_flex_slot :: proc(u: ^Ui, cross_size: i32) -> Rect_I32 {
	assert(u != nil, "ui_flex_slot: nil Ui")
	assert(u.open && cross_size >= 0, "ui_flex_slot: invalid call")
	r := flex_next(&u.layout)
	if layout_kind(&u.layout) == .Column {
		r.w = min(r.w, cross_size)
	} else {
		r.h = min(r.h, cross_size)
	}
	return r
}

// ui_row / ui_row_end / ui_space: thin conveniences over the Layout the Ui
// already owns; callers may equally use push_row(&u.layout, …) directly.
ui_row :: proc(u: ^Ui, h: i32, gap: i32 = 0) {
	assert(u.open, "ui_row: frame not open")
	push_row(&u.layout, h, gap)
}

ui_row_end :: proc(u: ^Ui) {
	assert(u.open, "ui_row_end: frame not open")
	layout_pop(&u.layout)
}

ui_space :: proc(u: ^Ui, px: i32) {
	assert(u.open, "ui_space: frame not open")
	spacer(&u.layout, px)
}

// label draws a plain text line, carving its own slot.
label :: proc(u: ^Ui, text: string, font_size: i32 = 0, color: rl.Color = {}) {
	assert(u.open, "label: frame not open")
	fs := font_size if font_size > 0 else FONT_SIZE
	col := color if color.a > 0 else theme.fg_primary
	text_c := strings.clone_to_cstring(text, context.temp_allocator)
	r := ui_slot(u, measure_text(text_c, fs), LINE_HEIGHT)
	draw_text(text_c, r.x, r.y + (r.h - fs) / 2, fs, col)
}

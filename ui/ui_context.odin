// LIB-CANDIDATE: imports only core:* and ingot:gfx.
// Ui is a caller-owned context bundling layout and keyboard focus. Static
// forms may use sequential registration; conditional and dynamic forms pass
// stable caller IDs whose traversal order is rebuilt in bounded frame arrays.
package ui

import "core:strings"
import rl "ingot:gfx"

// MAX_FOCUSABLES bounds focus registrations per frame (Tiger Style: put a
// limit on everything).
MAX_FOCUSABLES :: 256

Ui_Focus_Mode :: enum u8 {
	None,
	Sequential,
	Stable,
}

// Ui is caller-owned. Stable arrays retain only bounded traversal identity;
// widgets and their values remain entirely caller-owned.
Ui :: struct {
	layout:       Layout,
	focus_slot:   int,
	focus_count:  int,
	focus_seq:    int,
	stable_focus: Focus_State,
	stable_prev:  [MAX_FOCUSABLES]Focus_Id,
	stable_cur:   [MAX_FOCUSABLES]Focus_Id,
	stable_count: int,
	stable_seq:   int,
	focus_mode:   Ui_Focus_Mode,
	screen_w:     i32,
	screen_h:     i32,
	open:         bool,
}

// ui_begin opens the frame over the given area: caches screen size, runs Tab
// cycling against last frame's focusable count, and opens the root column.
ui_begin :: proc(u: ^Ui, x, y, w, h: i32, gap: i32 = 0) {
	assert(u != nil, "ui_begin: nil Ui")
	assert(!u.open, "ui_begin: frame already open")
	u.screen_w = rl.GetScreenWidth()
	u.screen_h = rl.GetScreenHeight()
	if u.focus_count > 0 do form_focus_cycle(&u.focus_slot, u.focus_count)
	if u.stable_count > 0 && rl.IsKeyPressed(.TAB) {
		backwards := rl.IsKeyDown(.LEFT_SHIFT) || rl.IsKeyDown(.RIGHT_SHIFT)
		ids := u.stable_prev[:u.stable_count]
		u.stable_focus.active = focus_order_next(ids, u.stable_focus.active, backwards)
	}
	u.focus_seq = 0
	u.stable_seq = 0
	u.focus_mode = .None
	layout_begin(&u.layout, x, y, w, h, gap)
	u.open = true
}

ui_end :: proc(u: ^Ui) {
	assert(u.open, "ui_end: frame not open")
	layout_end(&u.layout)
	if u.focus_mode == .Stable {
		if u.stable_focus.active != FOCUS_ID_NONE &&
		   focus_order_index(u.stable_cur[:u.stable_seq], u.stable_focus.active) < 0 {
			focus_clear(&u.stable_focus)
		}
		copy(u.stable_prev[:u.stable_seq], u.stable_cur[:u.stable_seq])
		u.stable_count = u.stable_seq
		u.focus_count = 0
	} else {
		u.focus_count = u.focus_seq
		u.stable_count = 0
	}
	u.open = false
}

ui_focus_sequential :: proc(u: ^Ui) -> Focus_Opt {
	assert(u.open, "ui_focus: frame not open")
	assert(u.focus_mode != .Stable, "ui_focus: mixed focus registration")
	assert(u.focus_seq < MAX_FOCUSABLES, "ui_focus: too many focusables")
	u.focus_mode = .Sequential
	u.focus_seq += 1
	return Focus_Opt{&u.focus_slot, u.focus_seq}
}

ui_focus_id :: proc(u: ^Ui, id: Focus_Id) -> Focus_Opt {
	assert(u.open, "ui_focus: frame not open")
	assert(id != FOCUS_ID_NONE, "ui_focus: zero stable id")
	assert(u.focus_mode != .Sequential, "ui_focus: mixed focus registration")
	assert(u.stable_seq < MAX_FOCUSABLES, "ui_focus: too many focusables")
	for registered in u.stable_cur[:u.stable_seq] {
		assert(registered != id, "ui_focus: duplicate stable id")
	}
	u.focus_mode = .Stable
	u.stable_cur[u.stable_seq] = id
	u.stable_seq += 1
	return focus_link(&u.stable_focus, id)
}

ui_focus :: proc {
	ui_focus_sequential,
	ui_focus_id,
}

ui_focus_clear :: proc(u: ^Ui) {
	assert(u != nil, "ui_focus_clear: nil Ui")
	assert(!u.open, "ui_focus_clear: frame open")
	u.focus_slot = 0
	focus_clear(&u.stable_focus)
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

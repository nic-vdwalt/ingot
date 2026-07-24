// LIB-CANDIDATE: imports only core:* and ingot:gfx.
// Keyboard focus-visible support links widgets to caller-owned sequential or
// stable focus state, plus the shared focus-ring rendering.
package ui


Focus_Id :: distinct u64
FOCUS_ID_NONE :: Focus_Id(0)

Focus_State :: struct {
	active: Focus_Id,
}

// Focus_Opt remains two machine words so existing sequential literals stay
// source-compatible. Stable links use the identical pointer-and-key layout.
Focus_Opt :: struct {
	focus: ^int,
	id:    int,
}

focus_id :: proc(value: u64) -> Focus_Id {
	assert(value != 0, "focus_id: zero is reserved")
	assert(value <= u64(max(int)), "focus_id: value exceeds platform int")
	id := Focus_Id(value)
	assert(id != FOCUS_ID_NONE, "focus_id: invalid id")
	return id
}

focus_clear :: proc(state: ^Focus_State) {
	assert(state != nil, "focus_clear: nil state")
	state.active = FOCUS_ID_NONE
	assert(state.active == FOCUS_ID_NONE, "focus_clear: focus not cleared")
}

focus_focused :: proc(state: ^Focus_State, id: Focus_Id) -> bool {
	assert(state != nil, "focus_focused: nil state")
	assert(id != FOCUS_ID_NONE, "focus_focused: zero id")
	return state.active == id
}

focus_link :: proc(state: ^Focus_State, id: Focus_Id) -> Focus_Opt {
	assert(state != nil, "focus_link: nil state")
	assert(id != FOCUS_ID_NONE, "focus_link: zero id")
	assert(u64(id) <= u64(max(int)), "focus_link: id exceeds platform int")
	return Focus_Opt{cast(^int)state, int(id)}
}

focus_opt_focused :: proc(f: Focus_Opt) -> bool {
	if f.focus == nil do return false
	assert(f.id > 0, "focus_opt_focused: focus ids are positive")
	assert(f.focus^ >= 0, "focus_opt_focused: negative focus slot")
	return f.focus^ == f.id
}

focus_opt_set :: proc(f: Focus_Opt) {
	assert(f.focus != nil, "focus_opt_set: nil focus")
	assert(f.id > 0, "focus_opt_set: focus ids are positive")
	f.focus^ = f.id
	assert(f.focus^ == f.id, "focus_opt_set: focus not set")
}

focus_opt_clear :: proc(f: Focus_Opt) {
	if f.focus == nil do return
	assert(f.id > 0, "focus_opt_clear: focus ids are positive")
	f.focus^ = 0
	assert(f.focus^ == 0, "focus_opt_clear: focus not cleared")
}

focus_opt_click :: proc(frame: ^Ui_Frame, f: Focus_Opt, x, y, w, h: i32) {
	if f.focus == nil do return
	assert(f.id > 0, "focus_opt_click: focus ids are positive")
	assert(w > 0 && h > 0, "focus_opt_click: empty rect")
	form_focus_input(frame, f.focus, f.id, x, y, w, h)
}

focus_activated :: proc(frame: ^Ui_Frame, focus: ^int, id: int) -> bool {
	assert(frame != nil && frame.open, "focus_activated: invalid frame")
	assert(focus != nil, "focus_activated: nil focus")
	assert(id > 0, "focus_activated: focus ids are positive")
	node_id := sem_node_id(.Button, {focus, id}, "", 0)
	if a11y_take_click(frame.runtime, node_id) {
		focus^ = id
		return true
	}
	if focus^ != id do return false
	return is_key_pressed(frame, .SPACE) || is_key_pressed(frame, .ENTER)
}

focus_opt_activated :: proc(frame: ^Ui_Frame, f: Focus_Opt) -> bool {
	if f.focus == nil do return false
	return focus_activated(frame, f.focus, f.id)
}

draw_focus_ring :: proc(frame: ^Ui_Frame, x, y, w, h: i32) {
	assert(w > 0 && h > 0, "draw_focus_ring: empty rect")
	style := ui_frame_theme(frame)
	assert(style.focus_ring.a > 0, "draw_focus_ring: focus ring has zero alpha")
	inset := ui_frame_sc(frame, 2)
	r := Rectangle{f32(x - inset), f32(y - inset), f32(w + inset * 2), f32(h + inset * 2)}
	draw_rectangle_rounded_lines_ex(
		frame,
		r,
		BTN_ROUNDNESS,
		BTN_SEGMENTS,
		ui_frame_scf(frame, 2.0),
		style.focus_ring,
	)
}

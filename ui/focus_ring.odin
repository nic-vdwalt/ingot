// LIB-CANDIDATE: imports only core:* and ingot:gfx.
// Keyboard focus-visible support: an optional link between a widget and a
// form_focus cycler slot, plus the shared focus-ring rendering every
// focusable widget draws when it owns the focused slot.
package ui

import rl "ingot:gfx"

// Focus_Opt optionally links a widget to a caller-owned form-focus cycler
// (see form_focus.odin). Zero value means "not focusable" — widgets behave
// exactly as before. Focus ids are 1-based: 0 means "nothing focused", so a
// zero-value Focus_Opt can never match a real slot.
Focus_Opt :: struct {
	focus: ^int, // caller's focus slot variable (cycled by form_focus_cycle)
	id:    int,  // this widget's 1-based id within the cycle
}

// focus_opt_focused reports whether the widget owning `f` holds keyboard
// focus this frame.
focus_opt_focused :: proc(f: Focus_Opt) -> bool {
	if f.focus == nil do return false
	assert(f.id > 0, "focus_opt_focused: focus ids are 1-based")
	assert(f.focus^ >= 0, "focus_opt_focused: negative focus slot")
	return f.focus^ == f.id
}

// focus_opt_click acquires focus for the widget when the mouse is pressed
// inside its rect (mirrors clicking into a text input).
focus_opt_click :: proc(f: Focus_Opt, x, y, w, h: i32) {
	if f.focus == nil do return
	assert(f.id > 0, "focus_opt_click: focus ids are 1-based")
	assert(w > 0 && h > 0, "focus_opt_click: empty rect")
	form_focus_input(f.focus, f.id, x, y, w, h)
}

// focus_activated reports whether the widget owning `id` was activated by
// keyboard this frame: it holds the focused slot and Space or Enter was
// pressed. Assistive-tech clicks (a11y_bridge.odin) flow through the same
// path so widgets need no separate AT handling. Usable by any widget, not
// just text inputs.
focus_activated :: proc(focus: ^int, id: int) -> bool {
	assert(focus != nil, "focus_activated: nil focus")
	assert(id > 0, "focus_activated: focus ids are 1-based")
	if a11y_take_click(focus, id) {
		focus^ = id
		return true
	}
	if focus^ != id do return false
	return rl.IsKeyPressed(.SPACE) || rl.IsKeyPressed(.ENTER)
}

// focus_opt_activated is focus_activated for an optional link (zero value
// never activates).
focus_opt_activated :: proc(f: Focus_Opt) -> bool {
	if f.focus == nil do return false
	return focus_activated(f.focus, f.id)
}

// draw_focus_ring draws the keyboard focus-visible indicator just outside a
// widget rect. Widgets call this when their Focus_Opt owns the focused slot.
draw_focus_ring :: proc(x, y, w, h: i32) {
	assert(w > 0 && h > 0, "draw_focus_ring: empty rect")
	// Why assert: an invisible ring silently breaks keyboard discoverability;
	// both built-in palettes define an opaque-ish focus_ring.
	assert(theme.focus_ring.a > 0, "draw_focus_ring: theme.focus_ring has zero alpha")
	r := rl.Rectangle{f32(x - 2), f32(y - 2), f32(w + 4), f32(h + 4)}
	rl.DrawRectangleRoundedLinesEx(r, BTN_ROUNDNESS, BTN_SEGMENTS, 2.0, theme.focus_ring)
}

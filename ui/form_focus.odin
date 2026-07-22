// Keyboard focus cycling for forms. The caller owns a single int focus slot;
// widget ids are 1-BASED (1..count) and 0 means "nothing focused". Tab moves
// forward, Shift+Tab backward, both wrapping. Widgets pair the slot with
// Focus_Opt (focus_ring.odin) for focus-visible rings and Space/Enter
// activation.
package ui

import rl "ingot:gfx"

form_focus_next :: proc(current, count: int, backwards: bool) -> int {
	assert(count > 0)
	assert(current >= 0)
	if current < 1 || current > count {
		return count if backwards else 1
	}
	if backwards {
		return count if current == 1 else current - 1
	}
	return 1 if current == count else current + 1
}

form_focus_cycle :: proc(focus: ^int, count: int) {
	assert(focus != nil)
	assert(count > 0)
	if !rl.IsKeyPressed(.TAB) do return
	backwards := rl.IsKeyDown(.LEFT_SHIFT) || rl.IsKeyDown(.RIGHT_SHIFT)
	focus^ = form_focus_next(focus^, count, backwards)
	assert(focus^ >= 1)
	assert(focus^ <= count)
}

form_focus_input :: proc(focus: ^int, id: int, x, y, w, h: i32) {
	assert(focus != nil)
	assert(id > 0)
	assert(w > 0)
	assert(h > 0)
	if !rl.IsMouseButtonPressed(.LEFT) do return
	rect := rl.Rectangle{f32(x), f32(y), f32(w), f32(h)}
	if rl.CheckCollisionPointRec(rl.GetMousePosition(), rect) {
		focus^ = id
		assert(focus^ == id)
	}
}

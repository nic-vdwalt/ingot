#+build !js
package ui

import "core:testing"

@(test)
interact_step_hover_only :: proc(t: ^testing.T) {
	it := interact_step(Interact_Event{over = true}, nil)
	testing.expect(t, it.hovered)
	testing.expect(t, !it.pressed && !it.held && !it.released && !it.clicked)
}

@(test)
interact_step_latchless_click_on_release_over :: proc(t: ^testing.T) {
	// Legacy button semantics: release over the rect activates.
	it := interact_step(Interact_Event{over = true, released = true}, nil)
	testing.expect(t, it.clicked)
	// Release outside does not.
	it = interact_step(Interact_Event{over = false, released = true}, nil)
	testing.expect(t, !it.clicked)
}

@(test)
interact_step_press_claims_latch :: proc(t: ^testing.T) {
	latch := false
	it := interact_step(Interact_Event{over = true, pressed = true, down = true}, &latch)
	testing.expect(t, it.pressed)
	testing.expect(t, it.held)
	testing.expect(t, latch)
}

@(test)
interact_step_press_outside_does_not_claim :: proc(t: ^testing.T) {
	latch := false
	it := interact_step(Interact_Event{over = false, pressed = true, down = true}, &latch)
	testing.expect(t, !it.pressed && !it.held)
	testing.expect(t, !latch)
}

@(test)
interact_step_drag_reports_held_outside_rect :: proc(t: ^testing.T) {
	latch := true
	it := interact_step(Interact_Event{over = false, down = true}, &latch)
	testing.expect(t, it.held)
	testing.expect(t, latch)
	// Hover tracks the pointer even mid-drag.
	testing.expect(t, !it.hovered)
	it = interact_step(Interact_Event{over = true, down = true}, &latch)
	testing.expect(t, it.hovered && it.held)
}

@(test)
interact_step_release_inside_clicks :: proc(t: ^testing.T) {
	latch := true
	it := interact_step(Interact_Event{over = true, released = true}, &latch)
	testing.expect(t, it.released)
	testing.expect(t, it.clicked)
	testing.expect(t, !it.held)
	testing.expect(t, !latch)
}

@(test)
interact_step_release_outside_no_click :: proc(t: ^testing.T) {
	latch := true
	it := interact_step(Interact_Event{over = false, released = true}, &latch)
	testing.expect(t, it.released)
	testing.expect(t, !it.clicked)
	testing.expect(t, !latch)
}

@(test)
interact_step_missed_release_drops_latch :: proc(t: ^testing.T) {
	// Focus loss / dropped event: button is up but no release edge arrived.
	latch := true
	it := interact_step(Interact_Event{over = true, down = false}, &latch)
	testing.expect(t, !it.held && !it.released && !it.clicked)
	testing.expect(t, !latch)
}

@(test)
interact_step_blocked_widget_is_inert :: proc(t: ^testing.T) {
	// While another widget drags, this one neither hovers nor activates.
	it := interact_step(
		Interact_Event{over = true, pressed = true, down = true, blocked = true},
		nil,
	)
	testing.expect(t, !it.hovered && !it.pressed && !it.clicked)
	latch := false
	it = interact_step(
		Interact_Event{over = true, pressed = true, down = true, blocked = true},
		&latch,
	)
	testing.expect(t, !it.held)
	testing.expect(t, !latch)
}

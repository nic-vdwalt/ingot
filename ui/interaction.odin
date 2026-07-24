// LIB-CANDIDATE: imports only core:* and ingot:gfx.
// Shared press/drag/release interaction protocol (the battle-tested Dear
// ImGui contract) as a pure helper. No keyed storage: the caller owns the
// drag latch (one bool per draggable widget); latch-less widgets get simple
// hover + release-over click semantics. A module-level pointer arbitrates
// exclusivity — one mouse means at most one active drag — without retaining
// any per-widget state in the library.
package ui

import rl "ingot:gfx"

// Interaction is the per-frame result of one widget's pointer protocol.
Interaction :: struct {
	hovered:  bool, // pointer over the rect (occlusion- and drag-aware)
	pressed:  bool, // press began inside the rect this frame
	held:     bool, // caller's latch is active (drag in progress)
	released: bool, // latch released this frame (at any position)
	clicked:  bool, // activation: release over the rect
}

// Interact_Event is the raw input snapshot interact_step consumes. Split out
// so the protocol core is pure and unit-testable without a window.
Interact_Event :: struct {
	over:       bool, // pointer inside the rect (already occlusion-resolved)
	pressed:    bool, // primary button press edge this frame
	released:   bool, // primary button release edge this frame
	down:       bool, // primary button currently held
	blocked:    bool, // another widget's drag latch is active
	press_over: bool, // the active press began inside the rect, unoccluded
}

// interact_step advances the interaction protocol one frame. Pure logic:
//   - press inside claims the latch (active is claimed on press);
//   - while latched, hover is reported and release fires `released`
//     anywhere, `clicked` only when the release lands inside;
//   - a missed release event (button no longer down) drops the latch;
//   - while another widget holds a latch, this widget stays inert;
//   - latch-less widgets report release-over as `clicked`, but only when
//     the press also began on the widget (press_over) — otherwise a press
//     that starts on an overlay and slides off it would leak a click to
//     the widget underneath.
interact_step :: proc(ev: Interact_Event, latch: ^bool) -> Interaction {
	it: Interaction
	if latch != nil && latch^ {
		it.held = true
		it.hovered = ev.over
		if ev.released {
			it.released = true
			it.clicked = ev.over
			it.held = false
			latch^ = false
		} else if !ev.down {
			// Missed release (focus loss, event drop): drop the latch quietly.
			it.held = false
			latch^ = false
		}
		return it
	}
	if ev.blocked do return it
	it.hovered = ev.over
	if ev.over && ev.pressed {
		it.pressed = true
		if latch != nil {
			latch^ = true
			it.held = true
		}
	}
	if latch == nil {
		it.clicked = ev.over && ev.released && ev.press_over
	}
	return it
}

Interaction_State :: struct {
	active_latch:   ^bool,
	press_pos:      rl.Vector2,
	press_occluded: bool,
	press_seen:     bool,
}

// interact_frame_begin snapshots the primary press origin for this frame.
// Called once per frame from begin_cursor_frame, after route_begin_frame
// (so the occlusion test sees the claims active this frame).
interact_frame_begin :: proc(frame: ^Ui_Frame) {
	assert(frame != nil && frame.open, "interact_frame_begin: invalid frame")
	if rl.IsMouseButtonPressed(.LEFT) {
		frame.interaction.press_pos = rl.GetMousePosition()
		frame.interaction.press_occluded = route_occluded(frame, frame.interaction.press_pos)
		frame.interaction.press_seen = true
	}
}

// interact_reset clears the drag arbitration slot and the recorded press
// origin (tests / teardown).
interact_reset :: proc(frame: ^Ui_Frame) {
	assert(frame != nil, "interact_reset: nil frame")
	frame.interaction = {}
}

// interact runs the interaction protocol for a widget rect. `rect` is in the
// widget's drawing space (pane-local when inside a translated split pane);
// the pointer is converted through the frame's pane scope here. Occlusion by
// overlay claims (route_claim) is resolved before hover is reported.
interact :: proc(frame: ^Ui_Frame, rect: rl.Rectangle, latch: ^bool = nil) -> Interaction {
	assert(frame != nil && frame.open, "interact: invalid frame")
	assert(rect.width >= 0 && rect.height >= 0, "interact: negative rect")
	state := &frame.interaction
	if state.active_latch != nil && !state.active_latch^ do state.active_latch = nil
	mouse := rl.GetMousePosition()
	local := frame_to_local(frame, mouse)
	local_press := frame_to_local(frame, state.press_pos)
	ev := Interact_Event {
		over       = rl.CheckCollisionPointRec(local, rect) && !route_occluded(frame, mouse),
		pressed    = rl.IsMouseButtonPressed(.LEFT),
		released   = rl.IsMouseButtonReleased(.LEFT),
		down       = rl.IsMouseButtonDown(.LEFT),
		blocked    = state.active_latch != nil && state.active_latch != latch,
		press_over = state.press_seen && !state.press_occluded && rl.CheckCollisionPointRec(local_press, rect),
	}
	it := interact_step(ev, latch)
	if latch != nil {
		if it.held {
			state.active_latch = latch
		} else if state.active_latch == latch {
			state.active_latch = nil
		}
	}
	return it
}

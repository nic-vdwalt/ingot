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

// Pointer to the drag latch currently held, so no other widget hovers or
// activates mid-drag. One mouse -> at most one active drag; this is frame
// arbitration, not retained widget state (the bool itself is caller-owned).
@(private = "file")
active_latch: ^bool

// Screen-space origin of the current primary press and whether an overlay
// claim covered it at press time. Snapshotted once per frame on the press
// edge (interact_frame_begin) so latch-less widgets can require the press
// to have started on them before reporting a release-over click.
@(private = "file")
press_pos: rl.Vector2
@(private = "file")
press_occluded: bool
@(private = "file")
press_seen: bool

// interact_frame_begin snapshots the primary press origin for this frame.
// Called once per frame from begin_cursor_frame, after route_begin_frame
// (so the occlusion test sees the claims active this frame).
interact_frame_begin :: proc() {
	if rl.IsMouseButtonPressed(.LEFT) {
		press_pos = rl.GetMousePosition()
		press_occluded = route_occluded(press_pos)
		press_seen = true
	}
}

// interact_reset clears the drag arbitration slot and the recorded press
// origin (tests / teardown).
interact_reset :: proc() {
	active_latch = nil
	press_pos = {}
	press_occluded = false
	press_seen = false
}

// interact runs the interaction protocol for a widget rect. `rect` is in the
// widget's drawing space (pane-local when inside a translated split pane);
// the pointer is converted via pane_origin_x in one place here. Occlusion by
// overlay claims (route_claim) is resolved before hover is reported.
interact :: proc(rect: rl.Rectangle, latch: ^bool = nil) -> Interaction {
	assert(rect.width >= 0 && rect.height >= 0, "interact: negative rect")
	// Stale arbitration: the caller reset its latch externally.
	if active_latch != nil && !active_latch^ {
		active_latch = nil
	}
	mouse := rl.GetMousePosition()
	local := mouse
	local.x -= f32(pane_origin_x)
	local_press := press_pos
	local_press.x -= f32(pane_origin_x)
	ev := Interact_Event {
		over       = rl.CheckCollisionPointRec(local, rect) && !route_occluded(mouse),
		pressed    = rl.IsMouseButtonPressed(.LEFT),
		released   = rl.IsMouseButtonReleased(.LEFT),
		down       = rl.IsMouseButtonDown(.LEFT),
		blocked    = active_latch != nil && active_latch != latch,
		press_over = press_seen &&
			!press_occluded &&
			rl.CheckCollisionPointRec(local_press, rect),
	}
	it := interact_step(ev, latch)
	if latch != nil {
		if it.held {
			active_latch = latch
		} else if active_latch == latch {
			active_latch = nil
		}
	}
	return it
}

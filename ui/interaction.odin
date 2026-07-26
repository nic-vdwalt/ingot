// LIB-CANDIDATE: imports only core:*.
// Shared press/drag/release interaction protocol (the battle-tested Dear
// ImGui contract) as a pure helper. No keyed storage: the caller owns the
// drag latch (one bool per draggable widget); latch-less widgets get simple
// hover + release-over click semantics. A module-level pointer arbitrates
// exclusivity — one mouse means at most one active drag — without retaining
// any per-widget state in the library.
package ui


// Interaction is the per-frame result of one widget's pointer protocol.
Interaction :: struct {
	hovered:  bool, // pointer over the rect (occlusion- and drag-aware)
	pressed:  bool, // press began inside the rect this frame
	held:     bool, // caller's latch is active (drag in progress)
	released: bool, // latch released this frame (at any position)
	clicked:  bool, // activation: release over the rect
}

Pressable_Config :: struct {
	rect:      Rect_I32,
	role:      Sem_Role,
	label:     string,
	stable_id: string,
	focus:     Focus_Opt,
	disabled:  bool,
	selected:  bool,
}

Pressable_Result :: struct {
	hovered:   bool,
	pressed:   bool,
	held:      bool,
	activated: bool,
	focused:   bool,
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
	// Runtime frame generation in which active_latch was last confirmed by
	// the widget that owns it. A latch whose owner stops being drawn is
	// otherwise never released, and `blocked` above then makes every widget
	// in the window inert. Compared, never used to reach the owner.
	latch_gen:      u64,
	press_pos:      Vector2,
	press_occluded: bool,
	press_seen:     bool,
}

// interact_frame_begin snapshots the primary press origin for this frame.
// Called once per frame from begin_cursor_frame, after route_begin_frame
// (so the occlusion test sees the claims active this frame).
interact_frame_begin :: proc(frame: ^Ui_Frame) {
	assert(frame != nil && frame.open, "interact_frame_begin: invalid frame")
	if is_mouse_button_pressed(frame, .LEFT) {
		frame.interaction.press_pos = get_mouse_position(frame)
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
interact :: proc(frame: ^Ui_Frame, rect: Rectangle, latch: ^bool = nil) -> Interaction {
	assert(frame != nil && frame.open, "interact: invalid frame")
	assert(rect.width >= 0 && rect.height >= 0, "interact: negative rect")
	state := &frame.interaction
	if state.active_latch != nil && !state.active_latch^ {
		state.active_latch = nil
		state.latch_gen = 0
	}
	mouse := get_mouse_position(frame)
	local := frame_to_local(frame, mouse)
	local_press := frame_to_local(frame, state.press_pos)
	ev := Interact_Event {
		over       = point_in_rect(local, rect) && !route_occluded(frame, mouse),
		pressed    = is_mouse_button_pressed(frame, .LEFT),
		released   = is_mouse_button_released(frame, .LEFT),
		down       = is_mouse_button_down(frame, .LEFT),
		blocked    = state.active_latch != nil && state.active_latch != latch,
		press_over = state.press_seen && !state.press_occluded && point_in_rect(local_press, rect),
	}
	it := interact_step(ev, latch)
	if latch != nil {
		if it.held {
			state.active_latch = latch
			state.latch_gen = frame.runtime.frame_generation
		} else if state.active_latch == latch {
			state.active_latch = nil
			state.latch_gen = 0
		}
	}
	return it
}

pressable :: proc(frame: ^Ui_Frame, config: Pressable_Config) -> Pressable_Result {
	assert(frame != nil && frame.open, "pressable: invalid frame")
	assert(config.rect.w > 0 && config.rect.h > 0, "pressable: empty rect")
	assert(config.role != .None && config.label != "", "pressable: semantics required")
	assert(config.stable_id != "", "pressable: stable id required")

	result: Pressable_Result
	result.focused = focus_opt_focused(config.focus)
	if !config.disabled {
		rect := config.rect
		it := interact(frame, {f32(rect.x), f32(rect.y), f32(rect.w), f32(rect.h)})
		focus_opt_click(frame, config.focus, rect.x, rect.y, rect.w, rect.h)
		result.hovered = it.hovered
		result.pressed = it.pressed
		result.held = it.held
		result.activated = it.clicked || focus_opt_activated(frame, config.focus)
		if result.hovered do request_cursor(frame, .POINTING_HAND)
	}
	state: Sem_State
	if config.disabled do state += {.Disabled}
	if config.selected do state += {.Selected}
	semantic_push(
		frame,
		config.role,
		config.rect,
		config.label,
		state,
		config.focus,
		config.stable_id,
	)
	return result
}

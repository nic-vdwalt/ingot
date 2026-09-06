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
	// Release over the rect activates when the press also began on it.
	it := interact_step(Interact_Event{over = true, released = true, press_over = true}, nil)
	testing.expect(t, it.clicked)
	// Release outside does not.
	it = interact_step(Interact_Event{over = false, released = true, press_over = true}, nil)
	testing.expect(t, !it.clicked)
}

@(test)
interact_step_latchless_press_elsewhere_no_click :: proc(t: ^testing.T) {
	// A press that began off the widget (e.g. on an overlay covering it)
	// must not click on release-over - that would leak overlay clicks to
	// the widgets underneath.
	it := interact_step(Interact_Event{over = true, released = true, press_over = false}, nil)
	testing.expect(t, !it.clicked)
	testing.expect(t, it.hovered)
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
interact_step_coalesced_tap_clicks_without_stale_latch :: proc(t: ^testing.T) {
	latch := false
	it := interact_step(Interact_Event{over = true, pressed = true, released = true}, &latch)
	testing.expect(t, it.pressed && it.released && it.clicked)
	testing.expect(t, !it.held)
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

@(test)
pressable_records_stable_selected_semantics :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	sem_enable(&runtime, true)
	frame: Ui_Frame
	ui_frame_begin(&frame, &runtime)
	result := pressable(
		&frame,
		{{0, 0, 100, 24}, .Option, "Detailed", "reasoning:detailed", {}, false, true},
	)
	testing.expect(t, !result.activated)
	testing.expect_value(t, frame.semantics.cur.count, 1)
	node := &frame.semantics.cur.nodes[0]
	testing.expect_value(t, node.id, sem_node_id(.Option, {}, "reasoning:detailed", 0))
	testing.expect(t, .Selected in node.state)
	ui_frame_end(&frame)
}

@(test)
pressable_disabled_is_inert_and_semantic :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	sem_enable(&runtime, true)
	frame: Ui_Frame
	ui_frame_begin(&frame, &runtime)
	result := pressable(
		&frame,
		{{0, 0, 100, 24}, .Button, "Delete", "delete:row", {}, true, false},
	)
	testing.expect(t, !result.hovered && !result.activated)
	testing.expect(t, .Disabled in frame.semantics.cur.nodes[0].state)
	ui_frame_end(&frame)
}

// interact_test_input builds a pointer-state snapshot for the frame-level
// arbitration tests below.
interact_test_input :: proc(
	mouse: Vec2 = {},
	pressed := false,
	released := false,
	down := false,
) -> Ui_Input {
	input: Ui_Input
	input.mouse_position = mouse
	input.mouse_pressed[input_mouse_index(.LEFT)] = pressed
	input.mouse_released[input_mouse_index(.LEFT)] = released
	input.mouse_down[input_mouse_index(.LEFT)] = down
	return input
}

@(test)
interaction_idle_no_route_preserves_hover_and_latches :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	frame: Ui_Frame
	latch: bool
	rect := Rectangle{0, 0, 100, 100}

	input := interact_test_input({10, 10})
	ui_frame_begin(&frame, &runtime, &input)
	it := interact(&frame, rect)
	testing.expect(t, it.hovered)
	testing.expect(t, !it.pressed && !it.held && !it.released && !it.clicked)
	testing.expect(t, frame.interaction.active_latch == nil)

	it = interact(&frame, rect, &latch)
	testing.expect(t, it.hovered)
	testing.expect(t, !it.pressed && !it.held && !it.released && !it.clicked)
	testing.expect(t, !latch)
	testing.expect(t, frame.interaction.active_latch == nil)

	it = interact(&frame, Rectangle{200, 200, 10, 10})
	testing.expect(t, !it.hovered)
	ui_frame_end(&frame)
}

// A latch owner that stops being drawn must not leave the window inert.
// Without generation reclamation the arbitration slot is only ever released
// from inside the owner's own interact() call, so a closed tab or swapped
// view would block every other widget forever.
@(test)
interaction_reclaims_latch_when_owner_disappears :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	frame: Ui_Frame
	dragging: bool
	rect := Rectangle{0, 0, 100, 100}

	// Frame 1: press inside the rect claims the latch.
	input := interact_test_input({10, 10}, pressed = true, down = true)
	ui_frame_begin(&frame, &runtime, &input)
	it := interact(&frame, rect, &dragging)
	testing.expect(t, it.held)
	testing.expect(t, dragging)
	testing.expect(t, frame.interaction.active_latch == &dragging)
	ui_frame_end(&frame)

	// Frame 2: the owner is not drawn at all (tab switched away). The latch
	// was confirmed in the immediately preceding frame, so it is still
	// considered live and other widgets remain blocked for exactly one frame.
	input = interact_test_input({10, 10}, down = true)
	ui_frame_begin(&frame, &runtime, &input)
	testing.expect(t, frame.interaction.active_latch == &dragging)
	blocked := interact(&frame, rect)
	testing.expect(t, !blocked.hovered)
	ui_frame_end(&frame)

	// Frame 3: the owner missed a full frame, so the slot is reclaimed and
	// an unrelated latch-less widget is reachable again.
	input = interact_test_input({10, 10}, down = true)
	ui_frame_begin(&frame, &runtime, &input)
	testing.expect(t, frame.interaction.active_latch == nil)
	testing.expect_value(t, frame.interaction.latch_gen, u64(0))
	other := interact(&frame, rect)
	testing.expect(t, other.hovered)
	ui_frame_end(&frame)
}

// A latch confirmed every frame must survive across frames: reclamation must
// not break a legitimate multi-frame drag.
@(test)
interaction_keeps_live_latch_across_frames :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	frame: Ui_Frame
	dragging: bool
	rect := Rectangle{0, 0, 100, 100}

	input := interact_test_input({10, 10}, pressed = true, down = true)
	ui_frame_begin(&frame, &runtime, &input)
	it := interact(&frame, rect, &dragging)
	testing.expect(t, it.held)
	ui_frame_end(&frame)

	// Drag continues for several frames with the pointer outside the rect.
	for _ in 0 ..< 4 {
		input = interact_test_input({500, 500}, down = true)
		ui_frame_begin(&frame, &runtime, &input)
		it = interact(&frame, rect, &dragging)
		testing.expect(t, it.held)
		testing.expect(t, dragging)
		testing.expect(t, frame.interaction.active_latch == &dragging)
		ui_frame_end(&frame)
	}

	// Release ends the drag and frees the slot.
	input = interact_test_input({500, 500}, released = true)
	ui_frame_begin(&frame, &runtime, &input)
	it = interact(&frame, rect, &dragging)
	testing.expect(t, it.released && !it.held && !it.clicked)
	testing.expect(t, !dragging)
	testing.expect(t, frame.interaction.active_latch == nil)
	ui_frame_end(&frame)
}

// interact_forget_block must clear a latch owned by a block about to be
// freed, using pointer comparison only so the owner is never dereferenced.
@(test)
interaction_forget_block_releases_owned_latch :: proc(t: ^testing.T) {
	Owner :: struct {
		padding:  [4]int,
		dragging: bool,
	}
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	frame: Ui_Frame
	owner := new(Owner)
	unrelated: bool
	rect := Rectangle{0, 0, 100, 100}

	input := interact_test_input({10, 10}, pressed = true, down = true)
	ui_frame_begin(&frame, &runtime, &input)
	it := interact(&frame, rect, &owner.dragging)
	testing.expect(t, it.held)
	testing.expect(t, frame.interaction.active_latch == &owner.dragging)

	// A block that does not contain the latch leaves it alone.
	interact_forget_block(&frame, rawptr(&unrelated), size_of(bool))
	testing.expect(t, frame.interaction.active_latch == &owner.dragging)

	// The owning block releases it, mid-frame, before the memory is freed.
	interact_forget_block(&frame, rawptr(owner), size_of(Owner))
	testing.expect(t, frame.interaction.active_latch == nil)
	testing.expect_value(t, frame.interaction.latch_gen, u64(0))
	free(owner)

	// Widgets drawn later in the same frame are no longer blocked, and no
	// freed memory is read to establish that.
	other := interact(&frame, rect)
	testing.expect(t, other.hovered)
	ui_frame_end(&frame)
}

// interact_forget is the single-latch form used by widgets that know their
// own state address (listbox_end, scrollbar_ex early-out).
@(test)
interaction_forget_releases_matching_latch_only :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	frame: Ui_Frame
	dragging: bool
	other_latch: bool
	rect := Rectangle{0, 0, 100, 100}

	input := interact_test_input({10, 10}, pressed = true, down = true)
	ui_frame_begin(&frame, &runtime, &input)
	_ = interact(&frame, rect, &dragging)
	testing.expect(t, frame.interaction.active_latch == &dragging)

	interact_forget(&frame, &other_latch)
	testing.expect(t, frame.interaction.active_latch == &dragging)
	interact_forget(&frame, nil)
	testing.expect(t, frame.interaction.active_latch == &dragging)

	interact_forget(&frame, &dragging)
	testing.expect(t, frame.interaction.active_latch == nil)
	testing.expect_value(t, frame.interaction.latch_gen, u64(0))
	ui_frame_end(&frame)
}

// A surface that claims its own rect must still activate its own widgets. The
// press origin is captured at frame begin, where no z scope is open, so a latch
// resolved there against the ambient depth reports every press inside the claim
// as occluded - including for the claimant. Hover and press visuals survive
// that (they are resolved inside the scope), which is why the failure looks
// like a button that highlights and depresses but never fires.
@(test)
interaction_click_inside_own_claim_activates :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	frame: Ui_Frame
	panel := Rectangle{0, 0, 200, 200}
	button := Rectangle{10, 10, 100, 30}

	// Frame 1: the panel claims its rect. Claims take effect next frame.
	input := interact_test_input({50, 20})
	ui_frame_begin(&frame, &runtime, &input)
	route_claim(&frame, panel, Z_PANEL)
	ui_frame_end(&frame)

	// Frame 2: the claim is live. A tap on the panel's own button, inside a
	// matching z scope, must click.
	input = interact_test_input({50, 20}, pressed = true, released = true)
	ui_frame_begin(&frame, &runtime, &input)
	route_claim(&frame, panel, Z_PANEL)
	z_scope_begin(&frame, Z_PANEL)
	it := interact(&frame, button)
	z_scope_end(&frame)
	testing.expect(t, it.hovered, "the claimant's own widget hovers")
	testing.expect(t, it.pressed, "the press lands on it")
	testing.expect(t, it.clicked, "and it activates")
	ui_frame_end(&frame)
}

// The same press, read at content depth, must stay inert: that is the whole
// point of the claim. Occlusion depends on the reader's depth, so one frame's
// press cannot be resolved to a single boolean.
@(test)
interaction_click_under_a_claim_stays_inert :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	frame: Ui_Frame
	panel := Rectangle{0, 0, 200, 200}
	canvas_widget := Rectangle{10, 10, 100, 30}

	input := interact_test_input({50, 20})
	ui_frame_begin(&frame, &runtime, &input)
	route_claim(&frame, panel, Z_PANEL)
	ui_frame_end(&frame)

	input = interact_test_input({50, 20}, pressed = true, released = true)
	ui_frame_begin(&frame, &runtime, &input)
	route_claim(&frame, panel, Z_PANEL)
	it := interact(&frame, canvas_widget)
	testing.expect(t, !it.hovered, "content under the panel does not hover")
	testing.expect(t, !it.clicked, "and does not click through")
	ui_frame_end(&frame)
}

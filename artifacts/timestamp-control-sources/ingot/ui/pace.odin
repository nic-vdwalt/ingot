// LIB-CANDIDATE: imports only core:*.
//
// Adaptive frame pacing. The pacer answers one question per frame - how hard
// should the app work right now - from user input, an app-supplied busy flag,
// and a grace window that keeps full rate for a short tail after activity
// stops (so release/hover/fade visuals settle).
//
// Two power decisions come out of that answer:
//
//   - A frame rate, returned to the caller to feed the renderer's frame
//     limiter. The caller must apply it; ui is renderer-independent.
//   - A frame strategy, published through Platform_Output so ui_gfx applies it
//     at end of frame. This one cannot be dropped by a forgetful caller, which
//     matters because it is the decision that actually reaches zero idle cost.
package ui

// Pacer_Mode selects what the pacer does once the grace window expires.
Pacer_Mode :: enum u8 {
	// Keep rendering, capped at idle_fps. Use when something animates
	// continuously and only needs to cost less, not stop.
	Throttle,
	// Stop rendering; the native pump blocks in platform_wait_events and the
	// web step() early-outs. Wakes on input, OS damage, RequestRedraw from a
	// worker, or a RequestRedrawIn deadline. Costs approximately zero while
	// idle, which Throttle cannot reach.
	//
	// Every asynchronous source the app owns must call RequestRedraw when it
	// produces work, or that work lands with no frame to display it.
	Event_Driven,
}

Frame_Pacer :: struct {
	target_fps:    i32,
	idle_fps:      i32,
	grace:         f64,
	last_activity: f64,
	current:       i32,
	mode:          Pacer_Mode,
	// Last strategy published, so a steady state emits no repeat request. See
	// pacer_frame for why re-requesting is not harmless.
	strategy:      Frame_Strategy,
	// False until the first pacer_frame, so the opening frame always publishes
	// its strategy rather than assuming the renderer already agrees.
	strategy_set:  bool,
}

pacer_init :: proc(
	target_fps: i32 = 60,
	idle_fps: i32 = 15,
	grace: f64 = 2.5,
	mode: Pacer_Mode = .Throttle,
) -> Frame_Pacer {
	assert(target_fps > 0 && idle_fps > 0, "pacer_init: invalid rate")
	assert(grace >= 0, "pacer_init: negative grace")
	return {
		target_fps = target_fps,
		idle_fps = idle_fps,
		grace = grace,
		current = target_fps,
		mode = mode,
	}
}

pacer_note_activity :: proc(p: ^Frame_Pacer, now: f64) {
	assert(p != nil, "pacer_note_activity: nil pacer")
	p.last_activity = now
}

// pacer_frame advances the pacer one frame and returns the frame rate to apply.
//
// In .Event_Driven mode it also publishes the frame strategy through the
// frame's Platform_Output, but only when the strategy changes. That guard is
// load-bearing rather than an optimization: the renderer's SetFrameStrategy
// marks activity internally, so re-requesting the same strategy every frame
// refills the settle burst forever and the app never actually idles.
pacer_frame :: proc(p: ^Frame_Pacer, frame: ^Ui_Frame, busy: bool = false) -> i32 {
	assert(p != nil && frame != nil, "pacer_frame: invalid argument")
	assert(p.target_fps > 0 && p.idle_fps > 0, "pacer_frame: uninitialized pacer")
	input := frame_input(frame)
	if busy || frame_user_input_active(frame) do p.last_activity = input.time
	active := input.time - p.last_activity < p.grace
	active_fps := max(input.monitor_refresh, p.target_fps)
	p.current = active_fps if active else p.idle_fps

	// Throttle never stops rendering, so it stays Continuous and relies purely
	// on the returned rate.
	want := Frame_Strategy.Continuous
	if p.mode == .Event_Driven && !active do want = .Event_Driven
	if !p.strategy_set || p.strategy != want {
		p.strategy = want
		p.strategy_set = true
		if frame.output != nil do platform_set_frame_strategy(&frame.output.platform, want)
	}
	return p.current
}

// pacer_frame_input is the pre-Platform_Output entry point: it paces from a raw
// input snapshot and can only throttle, because without a frame it has nowhere
// to publish a strategy. Prefer pacer_frame.
pacer_frame_input :: proc(p: ^Frame_Pacer, input: ^Ui_Input, busy: bool = false) -> i32 {
	assert(p != nil && input != nil, "pacer_frame_input: invalid argument")
	assert(p.target_fps > 0 && p.idle_fps > 0, "pacer_frame_input: uninitialized pacer")
	if busy || pacer_input_active(input) do p.last_activity = input.time
	active_fps := max(input.monitor_refresh, p.target_fps)
	p.current = active_fps if input.time - p.last_activity < p.grace else p.idle_fps
	return p.current
}

// pacer_input_active is superseded by frame_user_input_active, which also
// counts typed characters and held mouse/keyboard state - a drag or a key
// repeat is activity even on a frame with no fresh press event. Retained for
// pacer_frame_input and callers holding only a Ui_Input.
pacer_input_active :: proc(input: ^Ui_Input) -> bool {
	assert(input != nil, "pacer_input_active: nil input")
	if input.mouse_delta != {} || input.mouse_wheel != {} do return true
	if input_mouse_down(input, .LEFT) || input_mouse_down(input, .RIGHT) do return true
	for index in 0 ..< INPUT_KEY_COUNT {
		if input.keys_pressed[index] do return true
	}
	return false
}

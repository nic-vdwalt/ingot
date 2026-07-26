#+build !js
package ui

// Policy tests for the adaptive frame pacer. These exercise the decision
// itself — rate and frame strategy — with no renderer involved, so they run
// headless alongside the rest of the ui package.

import "core:testing"

// Pace_Harness owns the runtime/frame/output triple a pacer needs. It is always
// heap-allocated: Ui_Frame and Ui_Output embed fixed-capacity buffers that
// together overflow a test thread's stack.
@(private = "file")
Pace_Harness :: struct {
	runtime: Ui_Runtime,
	frame:   Ui_Frame,
	input:   Ui_Input,
	output:  Ui_Output,
}

@(private = "file")
pace_harness_make :: proc() -> ^Pace_Harness {
	h := new(Pace_Harness)
	ui_runtime_init(&h.runtime)
	h.frame.output = &h.output
	h.input.monitor_refresh = 60
	return h
}

@(private = "file")
pace_harness_destroy :: proc(h: ^Pace_Harness) {
	assert(h != nil, "pace_harness_destroy: nil harness")
	ui_frame_destroy(&h.frame)
	ui_runtime_destroy(&h.runtime)
	free(h)
}

// pace_step runs one full frame at time `now` and reports the decision.
//
// `strategy` is the pacer's retained choice and is always valid. `published`
// says whether the pacer wrote to Platform_Output this frame, and
// `published_strategy` is what it wrote — meaningful only when published is
// true, because platform_output_reset zeroes the buffer at the top of every
// frame. Steady-state frames publish nothing, which is the point.
@(private = "file")
pace_step :: proc(
	h: ^Pace_Harness,
	p: ^Frame_Pacer,
	now: f64,
	busy := false,
) -> (
	fps: i32,
	strategy: Frame_Strategy,
	published: bool,
	published_strategy: Frame_Strategy,
) {
	assert(h != nil && p != nil, "pace_step: invalid argument")
	h.input.time = now
	ui_frame_begin(&h.frame, &h.runtime, &h.input)
	fps = pacer_frame(p, &h.frame, busy)
	strategy = p.strategy
	published = h.output.platform.frame_strategy_requested
	published_strategy = h.output.platform.frame_strategy
	ui_frame_end(&h.frame)
	return
}

@(test)
pacer_throttle_never_requests_event_driven :: proc(t: ^testing.T) {
	h := pace_harness_make()
	defer pace_harness_destroy(h)
	pacer := pacer_init(60, 15, 2.5, .Throttle)

	// Opening frame publishes Continuous so the renderer is never assumed.
	first_fps, first_strategy, first_published, first_written := pace_step(h, &pacer, 0)
	testing.expect_value(t, first_fps, 60)
	testing.expect_value(t, first_strategy, Frame_Strategy.Continuous)
	testing.expect(t, first_published, "first frame should publish its strategy")
	testing.expect_value(t, first_written, Frame_Strategy.Continuous)

	// Well past the grace window: throttle drops the rate but keeps rendering.
	idle_fps, idle_strategy, idle_published, _ := pace_step(h, &pacer, 10)
	testing.expect_value(t, idle_fps, 15)
	testing.expect_value(t, idle_strategy, Frame_Strategy.Continuous)
	testing.expect(t, !idle_published, "throttle should never change strategy")
}

@(test)
pacer_event_driven_switches_after_grace :: proc(t: ^testing.T) {
	h := pace_harness_make()
	defer pace_harness_destroy(h)
	pacer := pacer_init(60, 15, 2.5, .Event_Driven)

	// Inside the grace window the app still renders at full rate.
	active_fps, active_strategy, _, _ := pace_step(h, &pacer, 1.0)
	testing.expect_value(t, active_fps, 60)
	testing.expect_value(t, active_strategy, Frame_Strategy.Continuous)

	// Past it, the pacer hands the loop to the event pump.
	idle_fps, idle_strategy, idle_published, idle_written := pace_step(h, &pacer, 5.0)
	testing.expect_value(t, idle_fps, 15)
	testing.expect_value(t, idle_strategy, Frame_Strategy.Event_Driven)
	testing.expect(t, idle_published, "crossing the grace boundary should publish")
	testing.expect_value(t, idle_written, Frame_Strategy.Event_Driven)
}

@(test)
pacer_deduplicates_steady_state :: proc(t: ^testing.T) {
	h := pace_harness_make()
	defer pace_harness_destroy(h)
	pacer := pacer_init(60, 15, 2.5, .Event_Driven)

	// This is the load-bearing case: SetFrameStrategy marks activity, so a
	// pacer that re-requests every frame refills the settle burst forever and
	// the app never actually idles.
	_, _, _, _ = pace_step(h, &pacer, 5.0) // transition into Event_Driven
	for step in 0 ..< 8 {
		_, strategy, published, _ := pace_step(h, &pacer, 6.0 + f64(step))
		testing.expect(t, !published, "steady state must not re-request")
		testing.expect_value(t, strategy, Frame_Strategy.Event_Driven)
	}

	// Waking back up is a transition, so it does publish.
	h.input.mouse_delta = {1, 0}
	_, wake_strategy, wake_published, wake_written := pace_step(h, &pacer, 20.0)
	h.input.mouse_delta = {}
	testing.expect_value(t, wake_strategy, Frame_Strategy.Continuous)
	testing.expect(t, wake_published, "waking should publish Continuous")
	testing.expect_value(t, wake_written, Frame_Strategy.Continuous)
}

@(test)
pacer_busy_pins_continuous :: proc(t: ^testing.T) {
	h := pace_harness_make()
	defer pace_harness_destroy(h)
	pacer := pacer_init(60, 15, 2.5, .Event_Driven)

	// No input at all, but the app reports work in flight (a running job, an
	// open socket): the pacer must not idle out from under it.
	for step in 0 ..< 5 {
		fps, strategy, _, _ := pace_step(h, &pacer, f64(step) * 10, busy = true)
		testing.expect_value(t, fps, 60)
		testing.expect_value(t, strategy, Frame_Strategy.Continuous)
	}
}

@(test)
pacer_input_resets_grace_window :: proc(t: ^testing.T) {
	h := pace_harness_make()
	defer pace_harness_destroy(h)
	pacer := pacer_init(60, 15, 2.5, .Event_Driven)

	_, idle_strategy, _, _ := pace_step(h, &pacer, 5.0)
	testing.expect_value(t, idle_strategy, Frame_Strategy.Event_Driven)

	// A held key counts as activity even with no fresh press event this frame.
	// pacer_input_active misses this; frame_user_input_active does not.
	key := input_key_index(.A)
	testing.expect(t, key >= 0, "key A should map to an index")
	h.input.keys_down[key] = true
	_, held_strategy, _, _ := pace_step(h, &pacer, 5.1)
	testing.expect_value(t, held_strategy, Frame_Strategy.Continuous)

	// Grace runs from the last activity, not from the last transition.
	h.input.keys_down[key] = false
	_, tail_strategy, _, _ := pace_step(h, &pacer, 7.0)
	testing.expect_value(t, tail_strategy, Frame_Strategy.Continuous)
	_, settled_strategy, _, _ := pace_step(h, &pacer, 8.0)
	testing.expect_value(t, settled_strategy, Frame_Strategy.Event_Driven)
}

@(test)
pacer_prefers_monitor_refresh :: proc(t: ^testing.T) {
	h := pace_harness_make()
	defer pace_harness_destroy(h)
	pacer := pacer_init(60, 15, 2.5, .Throttle)

	// A 144 Hz panel should not be limited to the 60 FPS default: capping below
	// the refresh rate fights vsync and oscillates.
	h.input.monitor_refresh = 144
	high_fps, _, _, _ := pace_step(h, &pacer, 0)
	testing.expect_value(t, high_fps, 144)

	// An unknown or slower refresh rate falls back to the configured target.
	h.input.monitor_refresh = 0
	fallback_fps, _, _, _ := pace_step(h, &pacer, 0.1)
	testing.expect_value(t, fallback_fps, 60)
}

@(test)
pacer_tolerates_frame_without_output :: proc(t: ^testing.T) {
	// Headless frames (tests, layout probes) carry no Ui_Output. The pacer must
	// still pace them rather than dereferencing a nil sink.
	h := pace_harness_make()
	defer pace_harness_destroy(h)
	h.frame.output = nil
	pacer := pacer_init(60, 15, 2.5, .Event_Driven)

	h.input.time = 10
	ui_frame_begin(&h.frame, &h.runtime, &h.input)
	fps := pacer_frame(&pacer, &h.frame)
	ui_frame_end(&h.frame)

	testing.expect_value(t, fps, 15)
	testing.expect_value(t, pacer.strategy, Frame_Strategy.Event_Driven)
}

@(test)
pacer_frame_input_still_throttles :: proc(t: ^testing.T) {
	// The pre-Platform_Output entry point stays available for callers holding
	// only a Ui_Input; it paces but cannot publish a strategy.
	pacer := pacer_init(60, 15, 2.5, .Event_Driven)
	input: Ui_Input
	input.monitor_refresh = 60

	input.time = 0
	testing.expect_value(t, pacer_frame_input(&pacer, &input), 60)
	input.time = 10
	testing.expect_value(t, pacer_frame_input(&pacer, &input), 15)
	testing.expect(t, !pacer.strategy_set, "input-only pacing publishes nothing")
}

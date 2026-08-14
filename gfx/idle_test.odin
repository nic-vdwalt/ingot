#+build !js
package gfx

import "core:testing"

@(test)
frame_strategy_is_context_bound :: proc(t: ^testing.T) {
	first := new(Context)
	defer free(first)
	second := new(Context)
	defer free(second)

	context_set_frame_strategy(first, .Event_Driven)
	context_set_frame_strategy(second, .Continuous)
	testing.expect_value(t, context_get_frame_strategy(first), Frame_Strategy.Event_Driven)
	testing.expect_value(t, context_get_frame_strategy(second), Frame_Strategy.Continuous)
	testing.expect_value(t, first.idle.settle_frames, i32(IDLE_SETTLE_FRAMES))
	testing.expect_value(t, second.idle.settle_frames, i32(IDLE_SETTLE_FRAMES))
}

@(test)
idle_continuous_always_runs :: proc(t: ^testing.T) {
	s := Idle_State{}
	for _ in 0 ..< 10 {
		testing.expect(t, _idle_take_frame(&s, 0))
	}
	testing.expect_value(t, s.settle_frames, i32(0))
}

@(test)
idle_settle_countdown :: proc(t: ^testing.T) {
	s := Idle_State {
		strategy = .Event_Driven,
	}
	_idle_note_activity(&s)
	for i in 0 ..< IDLE_SETTLE_FRAMES {
		testing.expect(t, _idle_take_frame(&s, f64(i)), "settle burst frame must run")
	}
	testing.expect(t, !_idle_take_frame(&s, 100), "idle after settle burst")
	// Renewed activity refills the full burst.
	_idle_note_activity(&s)
	testing.expect_value(t, s.settle_frames, i32(IDLE_SETTLE_FRAMES))
}

@(test)
idle_worker_redraw_is_consumed_on_render_thread :: proc(t: ^testing.T) {
	s := Idle_State {
		strategy = .Event_Driven,
	}
	_idle_request_redraw(&s)
	testing.expect_value(t, s.settle_frames, i32(0))
	testing.expect(t, _idle_take_frame(&s, 0), "published redraw must grant a frame")
	testing.expect_value(t, s.settle_frames, i32(IDLE_SETTLE_FRAMES - 1))
	testing.expect(t, !s.redraw_pending, "render thread must consume the request")
}

@(test)
idle_worker_redraw_requests_coalesce :: proc(t: ^testing.T) {
	s := Idle_State {
		strategy = .Event_Driven,
	}
	for _ in 0 ..< 1000 do _idle_request_redraw(&s)
	for _ in 0 ..< IDLE_SETTLE_FRAMES {
		testing.expect(t, _idle_take_frame(&s, 0), "coalesced request must preserve settle burst")
	}
	testing.expect(t, !_idle_take_frame(&s, 0), "coalesced requests must not spin")
}

@(test)
idle_redraw_during_settle_refills_burst :: proc(t: ^testing.T) {
	s := Idle_State {
		strategy = .Event_Driven,
	}
	_idle_note_activity(&s)
	testing.expect(t, _idle_take_frame(&s, 0))
	_idle_request_redraw(&s)
	testing.expect(t, _idle_take_frame(&s, 0))
	testing.expect_value(t, s.settle_frames, i32(IDLE_SETTLE_FRAMES - 1))
}

@(test)
idle_deadline_fires_and_clears :: proc(t: ^testing.T) {
	s := Idle_State {
		strategy = .Event_Driven,
	}
	_idle_request_in(&s, 10.0, 0.5)
	testing.expect_value(t, s.redraw_deadline, 10.5)
	// Before due: no frame, wait is trimmed to the remaining time.
	testing.expect(t, !_idle_take_frame(&s, 10.1))
	timeout := _idle_wait_timeout(&s, 10.1)
	testing.expect(t, timeout > 0.39 && timeout <= 0.41, "wait trimmed to deadline")
	// At/after due: frame runs, deadline cleared, settle burst granted.
	testing.expect(t, _idle_take_frame(&s, 10.5))
	testing.expect_value(t, s.redraw_deadline, 0.0)
	testing.expect_value(t, s.settle_frames, i32(IDLE_SETTLE_FRAMES - 1))
}

@(test)
idle_earliest_deadline_wins :: proc(t: ^testing.T) {
	s := Idle_State {
		strategy = .Event_Driven,
	}
	_idle_request_in(&s, 0, 2.0)
	_idle_request_in(&s, 0, 0.5)
	testing.expect_value(t, s.redraw_deadline, 0.5)
	_idle_request_in(&s, 0, 1.0) // later request must not push it back
	testing.expect_value(t, s.redraw_deadline, 0.5)
}

@(test)
idle_wait_capped :: proc(t: ^testing.T) {
	s := Idle_State {
		strategy = .Event_Driven,
	}
	testing.expect_value(t, _idle_wait_timeout(&s, 0), f64(IDLE_MAX_WAIT))
	_idle_request_in(&s, 0, 30.0)
	testing.expect_value(t, _idle_wait_timeout(&s, 0), f64(IDLE_MAX_WAIT))
	// A deadline already due yields the minimum positive slice, never negative.
	s.redraw_deadline = 1.0
	testing.expect_value(t, _idle_wait_timeout(&s, 5.0), 0.001)
}

@(test)
idle_negative_request_is_immediate :: proc(t: ^testing.T) {
	s := Idle_State {
		strategy = .Event_Driven,
	}
	_idle_request_in(&s, 10.0, -3.0) // clamped to "now"
	testing.expect_value(t, s.redraw_deadline, 10.0)
	testing.expect(t, _idle_take_frame(&s, 10.0))
}

@(test)
idle_web_gate_has_idle_floor :: proc(t: ^testing.T) {
	s := Idle_State {
		strategy = .Event_Driven,
	}
	// Run a burst: a redraw request grants a frame plus the settle credit.
	_idle_request_redraw(&s)
	testing.expect(t, _idle_web_gate(&s, 0), "redraw frame")
	testing.expect(t, _idle_web_gate(&s, 0.01), "settle frame")
	testing.expect(t, _idle_web_gate(&s, 0.02), "settle frame")
	testing.expect(t, !_idle_web_gate(&s, 0.1), "idle after the burst")
	// Fully idle: the gate still grants a floor frame once IDLE_MAX_WAIT
	// elapses since the last granted frame, so data arriving outside the
	// input path (WS/HTTP) becomes visible without user input.
	testing.expect(t, !_idle_web_gate(&s, IDLE_MAX_WAIT + 0.01), "floor not yet due")
	testing.expect(t, _idle_web_gate(&s, IDLE_MAX_WAIT + 0.02), "floor frame due")
	testing.expect(
		t,
		!_idle_web_gate(&s, IDLE_MAX_WAIT + 0.1),
		"floor resets after granting a frame",
	)
}

@(test)
idle_web_gate_grants_redraw_immediately :: proc(t: ^testing.T) {
	s := Idle_State {
		strategy = .Event_Driven,
	}
	testing.expect(t, !_idle_web_gate(&s, 0.5), "fresh idle state skips the frame")
	// A worker-published redraw grants a frame immediately (no floor wait).
	_idle_request_redraw(&s)
	testing.expect(t, _idle_web_gate(&s, 0.6), "published redraw must grant a frame")
	testing.expect_value(t, s.settle_frames, i32(IDLE_SETTLE_FRAMES - 1))
	testing.expect_value(t, s.last_frame_time, 0.6)
}

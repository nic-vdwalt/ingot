#+build !js
package gfx

import "core:testing"

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

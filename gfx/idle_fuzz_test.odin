#+build !js
package gfx

// Oracle for the animation/redraw contract: as long as a widget keeps
// honoring "unsettled => RequestRedraw", the event-driven pump must grant a
// frame every iteration (no mid-animation freeze), and once the ease snaps
// to target the pump must idle within IDLE_SETTLE_FRAMES (no spin).

import "core:testing"
import "ingot:testx"

@(test)
fuzz_idle_animation_lifecycle :: proc(t: ^testing.T) {
	p := testx.prng_make(0x11)
	for _ in 0 ..< 2_000 {
		s := Idle_State{strategy = .Event_Driven}
		speed := f32(testx.int_range(&p, 1, 30)) // widget speeds: 6..14
		dt := f32(testx.int_range(&p, 1, 50)) / 1000.0 // 1..50 ms frames
		anim: f32 = 0
		frames := 0
		for anim != 1 && frames < 100_000 {
			_idle_note_activity(&s) // the widget's RequestRedraw
			testing.expect(t, _idle_take_frame(&s, 0), "frame denied mid-animation")
			// Mirror of ui.eased(&anim, 1, dt, speed).
			k := clamp(speed * dt, 0, 1)
			anim += (1 - anim) * k
			if abs(1 - anim) < 0.001 do anim = 1
			frames += 1
		}
		testing.expect(t, anim == 1, "simulated animation failed to settle")
		granted := 0
		for _idle_take_frame(&s, 0) do granted += 1
		testing.expect(t, granted <= IDLE_SETTLE_FRAMES, "settle burst overshot")
		testing.expect(t, !_idle_take_frame(&s, 0), "pump failed to idle after settle")
	}
}

@(test)
fuzz_idle_deadline_wakeups :: proc(t: ^testing.T) {
	p := testx.prng_make(0x13)
	for _ in 0 ..< 2_000 {
		s := Idle_State{strategy = .Event_Driven}
		// Positive base time: a deadline of 0 is the "none" sentinel.
		now := 10.0
		// Drain any settle allowance so the pump is truly idle.
		for _idle_take_frame(&s, now) {}
		delay := f64(testx.int_range(&p, 0, 2_000)) / 1000.0
		_idle_request_in(&s, now, delay) // RequestRedrawIn
		testing.expect(t, delay == 0 || !_idle_take_frame(&s, now), "woke before deadline")
		now += delay
		testing.expect(t, _idle_take_frame(&s, now), "deadline wakeup missed")
	}
}

// ingot:gfx — event-driven frame scheduling (power-save) policy.
//
// Immediate-mode apps rebuild and present every frame even when nothing
// changes. With SetFrameStrategy(.Event_Driven) the engine instead idles
// between frames: the native pump blocks in platform_wait_events until input
// or OS damage arrives, and the web step() early-outs without running the app
// frame (the browser's rAF keeps ticking cheaply). The policy here is
// platform-neutral; platforms contribute two primitives — platform_wait_events
// and platform_wake — plus activity marks from their input callbacks.
//
// A frame runs when:
//   - input or OS damage arrives (platform callbacks call _idle_note_activity)
//   - the app calls RequestRedraw() (thread-safe; wakes a blocked native wait)
//   - a RequestRedrawIn(seconds) deadline falls due
// After any activity a burst of IDLE_SETTLE_FRAMES full frames runs before
// idling again, so hover/release/focus visuals settle (standard immediate-mode
// practice; egui does the same).
//
// Note for future platform work: any input source that is polled rather than
// callback-driven must also call _idle_note_activity, or event-driven apps
// will not wake for it.
package gfx

import "core:sync"

Frame_Strategy :: enum {
	Continuous, // today's behavior: a frame every loop iteration (default)
	Event_Driven, // idle between frames; wake on input/damage/redraw requests
}

// Frames rendered after the last activity before idling again.
IDLE_SETTLE_FRAMES :: 3

// Maximum seconds a native wait may block. Bounds close-button latency and
// guarantees a periodic frame (a ~1 fps idle floor keeps content fresh).
IDLE_MAX_WAIT :: 1.0

Idle_State :: struct {
	strategy:        Frame_Strategy,
	settle_frames:   i32, // full frames still owed after the last activity
	redraw_deadline: f64, // absolute _now() time of earliest RequestRedrawIn; 0 = none
	redraw_pending:  bool, // worker-published redraw request; accessed atomically
}

// --- public API -------------------------------------------------------------

SetFrameStrategy :: proc(s: Frame_Strategy) {
	g.idle.strategy = s
	_idle_note_activity(&g.idle) // render a settle burst across the transition
}

GetFrameStrategy :: proc() -> Frame_Strategy {
	return g.idle.strategy
}

// RequestRedraw schedules an immediate frame (plus settle burst). Safe to call
// from any thread ("c"/contextless): platform_wake unblocks a native wait in
// progress, so background work (net callbacks, timers) can trigger a repaint.
RequestRedraw :: proc "contextless" () {
	RequestRedrawContext(&default_context_storage)
}

RequestRedrawContext :: proc "contextless" (ctx: ^Context) {
	if ctx == nil do return
	_idle_request_redraw(&ctx.idle)
	platform_wake()
}

// RequestRedrawIn schedules a frame after `seconds` (caret blink, delayed
// animations). Multiple pending requests keep the earliest deadline.
RequestRedrawIn :: proc(seconds: f64) {
	RequestRedrawInContext(default_context(), seconds)
}

RequestRedrawInContext :: proc(ctx: ^Context, seconds: f64) {
	if ctx == nil do return
	now := platform_now() - ctx.start_time_s
	_idle_request_in(&ctx.idle, now, seconds)
}

// raylib-compat aliases.
EnableEventWaiting :: proc() {
	SetFrameStrategy(.Event_Driven)
}

DisableEventWaiting :: proc() {
	SetFrameStrategy(.Continuous)
}

// --- policy core (pure; unit-tested headless) -------------------------------

@(private)
_idle_note_activity :: proc "contextless" (s: ^Idle_State) {
	s.settle_frames = IDLE_SETTLE_FRAMES
}

@(private)
_idle_request_redraw :: proc "contextless" (s: ^Idle_State) {
	sync.atomic_store(&s.redraw_pending, true)
}

@(private)
_idle_request_in :: proc "contextless" (s: ^Idle_State, now, seconds: f64) {
	d := now + max(seconds, 0)
	if s.redraw_deadline == 0 || d < s.redraw_deadline {
		s.redraw_deadline = d
	}
}

// _idle_take_frame fires a due deadline and consumes one frame of settle
// credit; returns whether a frame should run now. Must be called exactly once
// per frame per target: from _idle_timeout on native, from step() on web.
@(private)
_idle_take_frame :: proc "contextless" (s: ^Idle_State, now: f64) -> bool {
	if sync.atomic_exchange(&s.redraw_pending, false) {
		s.settle_frames = max(s.settle_frames, IDLE_SETTLE_FRAMES)
	}
	if s.strategy == .Continuous do return true
	if s.redraw_deadline != 0 && now >= s.redraw_deadline {
		s.redraw_deadline = 0
		s.settle_frames = max(s.settle_frames, IDLE_SETTLE_FRAMES)
	}
	if s.settle_frames > 0 {
		s.settle_frames -= 1
		return true
	}
	return false
}

// _idle_wait_timeout returns how long the native pump may block: until the
// next deadline, capped at IDLE_MAX_WAIT.
@(private)
_idle_wait_timeout :: proc "contextless" (s: ^Idle_State, now: f64) -> f64 {
	t := f64(IDLE_MAX_WAIT)
	if s.redraw_deadline != 0 {
		t = min(t, max(s.redraw_deadline - now, 0.001))
	}
	return t
}

// _idle_timeout is the native pump gate, called once per frame from
// input_poll. Web never waits — rAF paces the loop and step() gates instead
// (waiting here would block the browser event loop).
@(private)
_idle_timeout :: proc() -> (should_wait: bool, timeout: f64) {
	when ODIN_OS == .JS {
		return false, 0
	} else {
		// Minimized: nothing is visible, so render nothing — just wait in
		// bounded slices (events still wake us; restore marks activity).
		if g.idle.strategy == .Event_Driven && platform_window_iconified() {
			return true, IDLE_MAX_WAIT
		}
		now := _now()
		if _idle_take_frame(&g.idle, now) {
			return false, 0
		}
		return true, _idle_wait_timeout(&g.idle, now)
	}
}

// LIB-CANDIDATE: imports only core:* and vendor:raylib.
// Adaptive frame pacing: run at full rate while anything is happening, drop
// to a low idle rate when the app is quiet. Ported from Alloy's main loop.
package ui

import rl "vendor:raylib"

// Frame_Pacer drops the render loop to idle_fps when there has been no user
// input or caller-reported activity for `grace` seconds, and restores full
// rate immediately on activity. The grace window lets time-based fade-outs
// and trailing animations finish smoothly before throttling.
Frame_Pacer :: struct {
	target_fps:    i32, // full-rate floor (matched up to the monitor refresh)
	idle_fps:      i32, // polling ceiling while idle
	grace:         f64, // seconds of full-rate rendering after last activity
	last_activity: f64,
	current:       i32, // last applied SetTargetFPS value
}

// pacer_init applies target_fps and returns an initialized pacer. Call after
// rl.InitWindow().
pacer_init :: proc(target_fps: i32 = 60, idle_fps: i32 = 15, grace: f64 = 2.5) -> Frame_Pacer {
	rl.SetTargetFPS(target_fps)
	return {target_fps, idle_fps, grace, rl.GetTime(), target_fps}
}

// pacer_note_activity marks external activity (network message, animation
// running, streaming output) so the loop stays at full rate.
pacer_note_activity :: proc(p: ^Frame_Pacer) {
	p.last_activity = rl.GetTime()
}

// pacer_frame updates the frame limiter; call once per frame (typically after
// rl.EndDrawing()). Input detection is non-consuming, so it never eats queued
// key/char events belonging to the app's handlers. `busy` forces full rate
// this frame (async work pending, run in progress, camera animating, ...).
pacer_frame :: proc(p: ^Frame_Pacer, busy: bool = false) {
	if busy || pacer_input_active() {
		p.last_activity = rl.GetTime()
	}
	if rl.GetTime()-p.last_activity < p.grace {
		// Match the frame limiter to the monitor's refresh rate so it never
		// fights vsync: a 60 FPS cap on top of vsync overshoots by a whole
		// sleep quantum and oscillates. Unknown refresh (0) → target_fps.
		active_fps := rl.GetMonitorRefreshRate(rl.GetCurrentMonitor())
		if active_fps < p.target_fps do active_fps = p.target_fps
		// Only call SetTargetFPS on transitions — it resets raylib's
		// internal frame-time bookkeeping every call.
		if p.current != active_fps {
			rl.SetTargetFPS(active_fps)
			p.current = active_fps
		}
	} else {
		if p.current != p.idle_fps {
			rl.SetTargetFPS(p.idle_fps)
			p.current = p.idle_fps
		}
	}
}

// pacer_input_active reports raw user input this frame (mouse move, buttons,
// wheel, keys). Uses only non-consuming state queries — GetKeyPressed /
// GetCharPressed pop from raylib's event queues and would steal events from
// the app's own input handling.
@(private)
pacer_input_active :: proc() -> bool {
	if rl.GetMouseDelta() != {0, 0} do return true
	if rl.GetMouseWheelMoveV() != {} do return true
	if rl.IsMouseButtonDown(.LEFT) || rl.IsMouseButtonDown(.RIGHT) do return true
	// Scan the keyboard state arrays (IsKeyPressed does not consume events).
	for k := i32(rl.KeyboardKey.SPACE); k <= i32(rl.KeyboardKey.KB_MENU); k += 1 {
		if rl.IsKeyPressed(rl.KeyboardKey(k)) do return true
	}
	return false
}

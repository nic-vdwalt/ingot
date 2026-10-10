// ingot:gfx - frame pacing, FPS metering, and the raylib-named window and
// screen queries and setters that read or adjust Context state.
package gfx

FRAME_PACING_SLEEP_THRESHOLD :: 0.002
FRAME_PACING_SLEEP_MARGIN :: 0.001
FRAME_PACING_SPINS_MAX :: 4096
#assert(FRAME_PACING_SLEEP_MARGIN > 0)
#assert(FRAME_PACING_SLEEP_THRESHOLD > FRAME_PACING_SLEEP_MARGIN)
#assert(FRAME_PACING_SPINS_MAX > 0)

@(private)
_frame_pacing_remaining :: proc(now, last, target: f64) -> f64 {
	assert(target > 0, "_frame_pacing_remaining: non-positive target")
	return clamp(target - (now - last), 0, target)
}

@(private)
_frame_pacing_enabled :: proc(target_fps: i32, close_requested: bool) -> bool {
	return target_fps > 0 && !close_requested
}

@(private)
_frame_timing :: proc(ctx: ^Context, close_requested: bool) {
	assert(ctx != nil, "_frame_timing: nil context")
	// Native pacing uses a bounded spin so a stalled clock cannot hang a frame.
	when ODIN_OS != .JS {
		if _frame_pacing_enabled(ctx.target_fps, close_requested) {
			target := 1.0 / f64(ctx.target_fps)
			assert(target > 0, "_frame_timing: non-positive target")
			remaining := _frame_pacing_remaining(_now(ctx), ctx.last_time, target)
			if remaining > FRAME_PACING_SLEEP_THRESHOLD {
				platform_sleep(remaining - FRAME_PACING_SLEEP_MARGIN)
			}
			for _ in 0 ..< FRAME_PACING_SPINS_MAX {
				remaining = _frame_pacing_remaining(_now(ctx), ctx.last_time, target)
				if remaining <= 0 do break
			}
			if remaining > 0 {
				platform_sleep(min(remaining, FRAME_PACING_SLEEP_THRESHOLD))
			}
		}
	}
	now := _now(ctx)
	raw := f32(max(now - ctx.last_time, 0))
	ctx.real_frame_time = raw
	// Clamp dt so a long gap (idle wait, browser tab hidden then resumed)
	// doesn't feed a huge step into animations/physics on the next frame.
	ctx.frame_time = min(raw, MAX_FRAME_TIME)
	ctx.last_time = now
	_fps_meter_record(&ctx.fps_meter, raw)
}

// GetFPS reports frames counted over each FPS_REFRESH_SECONDS window and holds
// that value until the next window closes, so the readout stays legible.
FPS_REFRESH_SECONDS :: 1.0
#assert(FPS_REFRESH_SECONDS > 0)

Fps_Meter :: struct {
	frames:    i32,
	elapsed:   f64,
	displayed: i32,
}

@(private)
_fps_meter_record :: proc(meter: ^Fps_Meter, frame_seconds: f32) {
	assert(meter != nil, "_fps_meter_record: nil meter")
	assert(meter.frames >= 0 && meter.elapsed >= 0)
	if frame_seconds <= 0 do return
	meter.frames += 1
	meter.elapsed += f64(frame_seconds)
	if meter.displayed == 0 {
		meter.displayed = i32(1.0 / f64(frame_seconds) + 0.5)
	}
	if meter.elapsed < FPS_REFRESH_SECONDS do return
	meter.displayed = i32(f64(meter.frames) / meter.elapsed + 0.5)
	meter.frames = 0
	meter.elapsed = 0
}

// MAX_FRAME_TIME caps GetFrameTime's reported delta (seconds).
MAX_FRAME_TIME :: 0.25

@(private)
_now :: proc(ctx: ^Context) -> f64 {
	assert(ctx != nil, "_now: nil context")
	return platform_now() - ctx.start_time_s
}

// --- window/screen queries (raylib-named) ----------------------------------

context_screen_width :: proc(ctx: ^Context) -> i32 {return ctx == nil ? 0 : ctx.width}
context_screen_height :: proc(ctx: ^Context) -> i32 {return ctx == nil ? 0 : ctx.height}
context_window_scale_dpi :: proc(ctx: ^Context) -> Vector2 {
	if ctx == nil do return {1, 1}
	return {ctx.dpi, ctx.dpi}
}
context_render_width :: proc(ctx: ^Context) -> i32 {return ctx == nil ? 0 : ctx.fb_width}
context_render_height :: proc(ctx: ^Context) -> i32 {return ctx == nil ? 0 : ctx.fb_height}
context_frame_time :: proc(ctx: ^Context) -> f32 {return ctx == nil ? 0 : ctx.frame_time}
context_time :: proc(ctx: ^Context) -> f64 {
	if ctx == nil do return 0
	return platform_now() - ctx.start_time_s
}
context_fps :: proc(ctx: ^Context) -> i32 {
	if ctx == nil do return 0
	return ctx.fps_meter.displayed
}

GetScreenWidth :: proc() -> i32 {return context_screen_width(default_context())}
GetScreenHeight :: proc() -> i32 {return context_screen_height(default_context())}
GetWindowScaleDPI :: proc() -> Vector2 {return context_window_scale_dpi(default_context())}
GetRenderWidth :: proc() -> i32 {return context_render_width(default_context())}
GetRenderHeight :: proc() -> i32 {return context_render_height(default_context())}

SetTargetFPS :: proc(fps: i32) {context_set_target_fps(default_context(), fps)}

set_vsync :: proc(enabled: bool) -> bool {return context_set_vsync(default_context(), enabled)}
GetFrameTime :: proc() -> f32 {return context_frame_time(default_context())}
GetTime :: proc() -> f64 {return context_time(default_context())}
GetFPS :: proc() -> i32 {return context_fps(default_context())}

context_set_window_min_size :: proc(ctx: ^Context, w, h: i32) {
	platform_set_window_min_size(ctx, w, h)
}
SetWindowMinSize :: proc(w, h: i32) {
	context_set_window_min_size(default_context(), w, h)
}
context_set_window_size :: proc(ctx: ^Context, w, h: i32) {
	platform_set_window_size(ctx, w, h)
}
SetWindowSize :: proc(w, h: i32) {
	context_set_window_size(default_context(), w, h)
}

context_set_window_title :: proc(ctx: ^Context, title: cstring) {
	assert(ctx != nil, "context_set_window_title: nil context")
	assert(title != nil, "context_set_window_title: nil title")
	platform_set_window_title(ctx, title)
}
SetWindowTitle :: proc(title: cstring) {
	context_set_window_title(default_context(), title)
}

// SetWindowPosition and GetWindowPosition address the window's placement on a
// monitor. A browser has no such placement: the page cannot move its own
// window and a canvas has no monitor coordinates, so on web the setter does
// nothing and the getter reports the canvas origin.
context_set_window_position :: proc(ctx: ^Context, x, y: i32) {
	platform_set_window_position(ctx, x, y)
}
SetWindowPosition :: proc(x, y: i32) {
	context_set_window_position(default_context(), x, y)
}

context_get_window_position :: proc(ctx: ^Context) -> Vector2 {
	assert(ctx != nil, "context_get_window_position: nil context")
	x, y := platform_window_position(ctx)
	return {f32(x), f32(y)}
}
GetWindowPosition :: proc() -> Vector2 {
	return context_get_window_position(default_context())
}

// IsWindowResized reports whether the logical window size changed at the start
// of the current frame. A DPI-only change is not a resize; see GetWindowScaleDPI.
IsWindowResized :: proc() -> bool {
	return context_window_resized(default_context())
}

context_window_resized :: proc(ctx: ^Context) -> bool {
	if ctx == nil do return false
	return ctx.resized_this_frame
}
context_set_exit_key :: proc(ctx: ^Context, key: KeyboardKey) {
	if ctx == nil do return
	ctx.inp.exit_key = key
}
SetExitKey :: proc(key: KeyboardKey) {context_set_exit_key(default_context(), key)}

GetMonitorRefreshRate :: proc(monitor: i32) -> i32 {
	return context_monitor_refresh_rate(default_context())
}
GetCurrentMonitor :: proc() -> i32 {return 0}

IsWindowFocused :: proc() -> bool {
	return context_window_focused(default_context())
}

window_occluded :: proc() -> bool {
	return context_window_occluded(default_context())
}

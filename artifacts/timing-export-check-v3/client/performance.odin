package main

import "core:math"
import "core:time"

PERFORMANCE_REFRESH_FALLBACK :: i32(60)
PERFORMANCE_MISS_TOLERANCE :: f32(1.03)
PERFORMANCE_MISS_WINDOW :: u32(240)
PERFORMANCE_DRAW_RESERVE_RATIO :: f32(0.72)
PERFORMANCE_FPS_SMOOTH_SECONDS :: f32(0.5)
PERFORMANCE_FPS_DISPLAY_INTERVAL_SECONDS :: f32(0.25)
PERFORMANCE_FPS_MAX_FRAME_SECONDS :: f32(0.25)
PERFORMANCE_RENDER_SCALE_MIN :: f32(0.75)
PERFORMANCE_RENDER_SCALE_STEP :: f32(0.05)
PERFORMANCE_GPU_DOWN_RATIO :: f32(1.05)
PERFORMANCE_GPU_UP_RATIO :: f32(0.78)
PERFORMANCE_GPU_DOWN_SAMPLES :: u32(12)
PERFORMANCE_GPU_UP_SAMPLES :: u32(240)
PERFORMANCE_GPU_COOLDOWN_SAMPLES :: u32(120)
PERFORMANCE_TARGET_ALIGNMENT :: i32(2)

Performance_State :: struct {
	refresh_rate:        i32,
	target_seconds:      f32,
	render_scale:        f32,
	fixed_quality:       bool,
	frame_started:       time.Tick,
	window_frames:       u32,
	window_misses:       u32,
	total_frames:        u64,
	total_misses:        u64,
	pressure:            f32,
	fps_frame_seconds:   f32,
	fps_display_elapsed: f32,
	fps_display:         i32,
	gpu_frame:           u64,
	gpu_ewma_seconds:    f32,
	gpu_over_samples:    u32,
	gpu_under_samples:   u32,
	gpu_cooldown:        u32,
}

performance_refresh_rate :: proc(refresh_rate: i32) -> i32 {
	return refresh_rate if refresh_rate > 0 else PERFORMANCE_REFRESH_FALLBACK
}

performance_target_seconds :: proc(refresh_rate: i32) -> f32 {
	return 1 / f32(performance_refresh_rate(refresh_rate))
}

performance_fps_record :: proc(value: ^Performance_State, frame_seconds: f32) -> bool {
	assert(value != nil, "performance_fps_record: nil state")
	if frame_seconds <= 0 do return false
	elapsed := min(frame_seconds, PERFORMANCE_FPS_MAX_FRAME_SECONDS)
	if value.fps_frame_seconds <= 0 {
		value.fps_frame_seconds = elapsed
		value.fps_display_elapsed = 0
		value.fps_display = i32(1 / elapsed + 0.5)
		return true
	}
	blend := clamp(1 - math.exp(-elapsed / PERFORMANCE_FPS_SMOOTH_SECONDS), f32(0), f32(1))
	value.fps_frame_seconds += (elapsed - value.fps_frame_seconds) * blend
	value.fps_display_elapsed += elapsed
	if value.fps_display_elapsed < PERFORMANCE_FPS_DISPLAY_INTERVAL_SECONDS do return false
	value.fps_display_elapsed -= PERFORMANCE_FPS_DISPLAY_INTERVAL_SECONDS
	value.fps_display = i32(1 / value.fps_frame_seconds + 0.5)
	return true
}

performance_init :: proc(refresh_rate: i32) -> Performance_State {
	refresh := performance_refresh_rate(refresh_rate)
	return {
		refresh_rate = refresh,
		target_seconds = performance_target_seconds(refresh),
		render_scale = 1,
	}
}

performance_sync_refresh :: proc(value: ^Performance_State, refresh_rate: i32) -> bool {
	assert(value != nil, "performance_sync_refresh: nil state")
	refresh := performance_refresh_rate(refresh_rate)
	if value.refresh_rate == refresh && value.target_seconds > 0 do return false
	value.refresh_rate = refresh
	value.target_seconds = performance_target_seconds(refresh)
	value.window_frames = 0
	value.window_misses = 0
	value.pressure = 0
	if !value.fixed_quality do value.render_scale = 1
	return true
}

performance_frame_record :: proc(value: ^Performance_State, frame_seconds: f32) -> bool {
	assert(value != nil, "performance_frame_record: nil state")
	if value.target_seconds <= 0 do _ = performance_sync_refresh(value, value.refresh_rate)
	_ = performance_fps_record(value, frame_seconds)
	elapsed := max(frame_seconds, f32(0))
	ratio := elapsed / value.target_seconds
	missed := ratio > PERFORMANCE_MISS_TOLERANCE
	value.total_frames += 1
	value.window_frames += 1
	if missed {
		value.total_misses += 1
		value.window_misses += 1
	}
	value.pressure = clamp(max(ratio - 1, f32(0)), f32(0), f32(4))
	if value.window_frames >= PERFORMANCE_MISS_WINDOW {
		value.window_frames = 0
		value.window_misses = 0
	}
	return false
}

performance_miss_ratio :: proc(value: ^Performance_State) -> f32 {
	if value == nil || value.total_frames == 0 do return 0
	return f32(value.total_misses) / f32(value.total_frames)
}

performance_gpu_record :: proc(
	value: ^Performance_State,
	frame_index: u64,
	gpu_seconds: f64,
	valid: bool,
) -> bool {
	assert(value != nil, "performance_gpu_record: nil state")
	if value.fixed_quality do return false
	if !valid || gpu_seconds <= 0 || frame_index == value.gpu_frame do return false
	value.gpu_frame = frame_index
	sample := f32(min(gpu_seconds, f64(PERFORMANCE_FPS_MAX_FRAME_SECONDS)))
	if value.gpu_ewma_seconds <= 0 {
		value.gpu_ewma_seconds = sample
	} else {
		value.gpu_ewma_seconds += (sample - value.gpu_ewma_seconds) * 0.08
	}
	if value.gpu_cooldown > 0 do value.gpu_cooldown -= 1
	over := value.gpu_ewma_seconds > value.target_seconds * PERFORMANCE_GPU_DOWN_RATIO
	under := value.gpu_ewma_seconds < value.target_seconds * PERFORMANCE_GPU_UP_RATIO
	value.gpu_over_samples = value.gpu_over_samples + 1 if over else 0
	value.gpu_under_samples = value.gpu_under_samples + 1 if under else 0
	if value.gpu_cooldown > 0 do return false
	if value.gpu_over_samples >= PERFORMANCE_GPU_DOWN_SAMPLES &&
	   value.render_scale > PERFORMANCE_RENDER_SCALE_MIN {
		value.render_scale = max(
			value.render_scale - PERFORMANCE_RENDER_SCALE_STEP,
			PERFORMANCE_RENDER_SCALE_MIN,
		)
	} else if value.gpu_under_samples >= PERFORMANCE_GPU_UP_SAMPLES && value.render_scale < 1 {
		value.render_scale = min(value.render_scale + PERFORMANCE_RENDER_SCALE_STEP, f32(1))
	} else {
		return false
	}
	value.gpu_over_samples = 0
	value.gpu_under_samples = 0
	value.gpu_cooldown = PERFORMANCE_GPU_COOLDOWN_SAMPLES
	return true
}

performance_render_size :: proc(width, height: i32, scale: f32 = 1) -> (i32, i32) {
	if width <= 0 || height <= 0 do return 0, 0
	bounded := clamp(scale, PERFORMANCE_RENDER_SCALE_MIN, f32(1))
	aligned_width :=
		i32(f32(width) * bounded) / PERFORMANCE_TARGET_ALIGNMENT * PERFORMANCE_TARGET_ALIGNMENT
	aligned_height :=
		i32(f32(height) * bounded) / PERFORMANCE_TARGET_ALIGNMENT * PERFORMANCE_TARGET_ALIGNMENT
	return max(
		aligned_width,
		PERFORMANCE_TARGET_ALIGNMENT,
	), max(aligned_height, PERFORMANCE_TARGET_ALIGNMENT)
}

performance_optional_budget_available :: proc(
	value: ^Performance_State,
	elapsed_seconds: f32,
) -> bool {
	if value == nil || value.target_seconds <= 0 do return true
	return elapsed_seconds < value.target_seconds * PERFORMANCE_DRAW_RESERVE_RATIO
}

performance_optional_budget_now :: proc(value: ^Performance_State) -> bool {
	if value == nil do return true
	elapsed := f32(time.duration_seconds(time.tick_since(value.frame_started)))
	return performance_optional_budget_available(value, elapsed)
}

package main

import "core:testing"

@(test)
performance_fixed_quality_preserves_scale :: proc(t: ^testing.T) {
	value := performance_init(120)
	value.fixed_quality = true
	value.render_scale = 0.85
	for frame in 1 ..< 100 {
		testing.expect(t, !performance_gpu_record(&value, u64(frame), 0.1, true))
	}
	_ = performance_sync_refresh(&value, 60)
	testing.expect_value(t, value.render_scale, f32(0.85))
}

@(test)
performance_refresh_target_uses_monitor_and_fallback :: proc(t: ^testing.T) {
	testing.expect_value(t, performance_refresh_rate(120), i32(120))
	testing.expect_value(t, performance_refresh_rate(144), i32(144))
	testing.expect_value(t, performance_refresh_rate(0), PERFORMANCE_REFRESH_FALLBACK)
	testing.expect(t, abs(performance_target_seconds(60) - f32(1.0 / 60.0)) < 0.000001)
	testing.expect(t, abs(performance_target_seconds(120) - f32(1.0 / 120.0)) < 0.000001)
}

@(test)
performance_fps_initializes_from_first_valid_frame :: proc(t: ^testing.T) {
	value := performance_init(60)
	testing.expect(t, !performance_fps_record(&value, 0))
	testing.expect(t, !performance_fps_record(&value, -1))
	testing.expect_value(t, value.fps_display, i32(0))
	testing.expect(t, performance_fps_record(&value, f32(1.0 / 60.0)))
	testing.expect_value(t, value.fps_display, i32(60))
}

@(test)
performance_fps_smooths_frame_duration :: proc(t: ^testing.T) {
	value := performance_init(60)
	_ = performance_fps_record(&value, f32(1.0 / 60.0))
	previous := value.fps_frame_seconds
	testing.expect(t, !performance_fps_record(&value, f32(1.0 / 30.0)))
	testing.expect(t, value.fps_frame_seconds > previous)
	testing.expect(t, value.fps_frame_seconds < f32(1.0 / 30.0))
	testing.expect_value(t, value.fps_display, i32(60))
}

@(test)
performance_fps_publishes_at_four_hertz :: proc(t: ^testing.T) {
	value := performance_init(60)
	_ = performance_fps_record(&value, f32(1.0 / 60.0))
	step := PERFORMANCE_FPS_DISPLAY_INTERVAL_SECONDS / 4
	for _ in 0 ..< 3 {
		testing.expect(t, !performance_fps_record(&value, step))
	}
	testing.expect(t, performance_fps_record(&value, step))
	testing.expect(t, value.fps_display < 60)
}

@(test)
performance_fps_clamps_long_frames :: proc(t: ^testing.T) {
	value := performance_init(60)
	testing.expect(t, performance_fps_record(&value, 10))
	testing.expect_value(t, value.fps_frame_seconds, PERFORMANCE_FPS_MAX_FRAME_SECONDS)
	testing.expect_value(t, value.fps_display, i32(4))
}

@(test)
performance_records_misses_without_reducing_quality :: proc(t: ^testing.T) {
	value := performance_init(120)
	testing.expect(t, !performance_frame_record(&value, value.target_seconds * 2))
	testing.expect(t, value.fps_display > 0)
	testing.expect_value(t, value.total_misses, u64(1))
	testing.expect_value(t, value.render_scale, f32(1))
	width, height := performance_render_size(1920, 1080)
	testing.expect_value(t, width, i32(1920))
	testing.expect_value(t, height, i32(1080))
}

@(test)
performance_miss_accounting_is_bounded :: proc(t: ^testing.T) {
	value := performance_init(60)
	for _ in 0 ..< 20 do _ = performance_frame_record(&value, value.target_seconds * 2)
	testing.expect_value(t, value.render_scale, f32(1))
	testing.expect_value(t, value.total_misses, u64(20))
	testing.expect_value(t, performance_miss_ratio(&value), f32(1))
}

@(test)
performance_refresh_change_resets_pressure_without_resetting_quality :: proc(t: ^testing.T) {
	value := performance_init(60)
	_ = performance_frame_record(&value, value.target_seconds * 2)
	testing.expect(t, performance_sync_refresh(&value, 144))
	testing.expect_value(t, value.refresh_rate, i32(144))
	testing.expect_value(t, value.render_scale, f32(1))
	testing.expect_value(t, value.pressure, f32(0))
	testing.expect(t, !performance_sync_refresh(&value, 144))
}

@(test)
performance_render_size_scales_and_aligns_world_targets :: proc(t: ^testing.T) {
	width, height := performance_render_size(1920, 1080)
	testing.expect_value(t, width, i32(1920))
	testing.expect_value(t, height, i32(1080))
	width, height = performance_render_size(1920, 1080, 0.75)
	testing.expect_value(t, width, i32(1440))
	testing.expect_value(t, height, i32(810))
	width, height = performance_render_size(0, 1080)
	testing.expect_value(t, width, i32(0))
	testing.expect_value(t, height, i32(0))
}

@(test)
performance_gpu_scaling_rejects_spikes_and_recovers_slowly :: proc(t: ^testing.T) {
	value := performance_init(120)
	testing.expect(t, !performance_gpu_record(&value, 1, 0.02, true))
	testing.expect_value(t, value.render_scale, f32(1))
	for frame in 2 ..= u64(PERFORMANCE_GPU_DOWN_SAMPLES) {
		_ = performance_gpu_record(&value, frame, 0.02, true)
	}
	testing.expect_value(t, value.render_scale, f32(0.95))
	for frame in PERFORMANCE_GPU_DOWN_SAMPLES +
		1 ..= PERFORMANCE_GPU_DOWN_SAMPLES + PERFORMANCE_GPU_COOLDOWN_SAMPLES {
		_ = performance_gpu_record(&value, u64(frame), 0.001, true)
	}
	testing.expect_value(t, value.render_scale, f32(0.95))
	for offset in 1 ..= PERFORMANCE_GPU_UP_SAMPLES {
		_ = performance_gpu_record(
			&value,
			u64(PERFORMANCE_GPU_DOWN_SAMPLES + PERFORMANCE_GPU_COOLDOWN_SAMPLES + offset),
			0.001,
			true,
		)
	}
	testing.expect(t, value.render_scale > 0.95)
}

@(test)
performance_gpu_scaling_ignores_missing_and_duplicate_samples :: proc(t: ^testing.T) {
	value := performance_init(120)
	testing.expect(t, !performance_gpu_record(&value, 1, 0.02, false))
	testing.expect(t, !performance_gpu_record(&value, 1, 0.02, true))
	over := value.gpu_over_samples
	testing.expect(t, !performance_gpu_record(&value, 1, 0.04, true))
	testing.expect_value(t, value.gpu_over_samples, over)
}

@(test)
performance_optional_budget_reserves_the_draw_tail :: proc(t: ^testing.T) {
	value := performance_init(120)
	testing.expect(t, performance_optional_budget_available(&value, value.target_seconds * 0.5))
	testing.expect(t, !performance_optional_budget_available(&value, value.target_seconds * 0.8))
}

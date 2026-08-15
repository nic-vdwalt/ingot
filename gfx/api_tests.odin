#+build !js
package gfx

import "core:testing"

frame_owner_test_context: Context

@(test)
context_queries_are_isolated :: proc(t: ^testing.T) {
	first := new(Context)
	second := new(Context)
	defer free(first)
	defer free(second)
	first.width, first.height, first.dpi, first.frame_time = 640, 360, 1, 0.01
	second.width, second.height, second.dpi, second.frame_time = 320, 240, 2, 0.02
	first.inp.mouse = {10, 20}
	second.inp.mouse = {30, 40}
	first.inp.pressed[KeyboardKey.A] = true
	testing.expect_value(t, context_screen_width(first), i32(640))
	testing.expect_value(t, context_screen_width(second), i32(320))
	testing.expect_value(t, context_get_mouse_position(first), Vector2{10, 20})
	testing.expect_value(t, context_get_mouse_position(second), Vector2{30, 40})
	testing.expect(t, context_is_key_pressed(first, .A))
	testing.expect(t, !context_is_key_pressed(second, .A))
}

@(test)
default_context_can_be_bound_across_library_boundaries :: proc(t: ^testing.T) {
	gfx_shared_test_lock()
	defer gfx_shared_test_unlock()
	bound := new(Context)
	defer free(bound)
	previous := set_default_context(bound)
	testing.expect(t, default_context() == bound)
	testing.expect(t, set_default_context(previous) == bound)
	testing.expect(t, default_context() == previous)
}

@(test)
default_input_wrappers_and_explicit_context_are_isolated :: proc(t: ^testing.T) {
	gfx_shared_test_lock()
	defer gfx_shared_test_unlock()
	ctx := new(Context)
	defer free(ctx)
	default_mouse := default_context_storage.inp.mouse
	default_pressed := default_context_storage.inp.pressed[KeyboardKey.A]
	default_key_down := default_context_storage.inp.key_down[KeyboardKey.A]
	default_mouse_down := default_context_storage.inp.mb_down[MouseButton.LEFT]
	defer {
		default_context_storage.inp.mouse = default_mouse
		default_context_storage.inp.pressed[KeyboardKey.A] = default_pressed
		default_context_storage.inp.key_down[KeyboardKey.A] = default_key_down
		default_context_storage.inp.mb_down[MouseButton.LEFT] = default_mouse_down
	}
	default_context_storage.inp.mouse = {10, 20}
	default_context_storage.inp.pressed[KeyboardKey.A] = false
	default_context_storage.inp.key_down[KeyboardKey.A] = false
	default_context_storage.inp.mb_down[MouseButton.LEFT] = false
	ctx.inp.mouse = {30, 40}
	ctx.inp.pressed[KeyboardKey.A] = true
	ctx.inp.key_down[KeyboardKey.A] = true
	ctx.inp.mb_down[MouseButton.LEFT] = true

	testing.expect_value(t, GetMousePosition(), Vector2{10, 20})
	testing.expect(t, !IsKeyPressed(.A))
	testing.expect(t, !IsKeyDown(.A))
	testing.expect(t, !IsMouseButtonDown(.LEFT))
	testing.expect_value(t, context_get_mouse_position(ctx), Vector2{30, 40})
	testing.expect(t, context_is_key_pressed(ctx, .A))
	testing.expect(t, context_is_key_down(ctx, .A))
	testing.expect(t, context_is_mouse_button_down(ctx, .LEFT))
}

@(test)
mouse_edges_reset_without_clearing_held_state :: proc(t: ^testing.T) {
	inp := Input{}
	inp.mb_pressed[0] = true
	inp.mb_released[0] = true
	inp.mb_down[0] = true

	_input_reset_mouse_edges(&inp)

	testing.expect(t, !inp.mb_pressed[0])
	testing.expect(t, !inp.mb_released[0])
	testing.expect(t, inp.mb_down[0])
}

@(test)
renderer_stats_reset_preserves_live_identity :: proc(t: ^testing.T) {
	ctx := new(Context)
	defer free(ctx)
	ctx.stats_current.frame_index = 7
	ctx.stats_current.composite_alpha_mode = .Premultiplied
	ctx.stats_current.flush_count = 3
	ctx.stats_latest.flush_count = 2
	context_renderer_stats_reset(ctx)
	when RENDER_STATS_ENABLED {
		testing.expect_value(t, ctx.stats_current.frame_index, u64(7))
		testing.expect(t, ctx.stats_current.composite_alpha_mode == .Premultiplied)
		testing.expect_value(t, ctx.stats_current.flush_count, u32(0))
		testing.expect_value(t, ctx.stats_latest.flush_count, u32(0))
	}
}

@(test)
frame_pacing_remaining_is_bounded :: proc(t: ^testing.T) {
	start := _frame_pacing_remaining(10.0, 10.0, 0.1)
	middle := _frame_pacing_remaining(10.05, 10.0, 0.1)
	reached := _frame_pacing_remaining(10.2, 10.0, 0.1)
	regressed := _frame_pacing_remaining(9.0, 10.0, 0.1)
	testing.expect(t, abs(start - 0.1) < 0.000001)
	testing.expect(t, abs(middle - 0.05) < 0.000001)
	testing.expect_value(t, reached, 0.0)
	testing.expect(t, abs(regressed - 0.1) < 0.000001)
}

@(test)
close_requested_disables_frame_pacing :: proc(t: ^testing.T) {
	testing.expect(t, _frame_pacing_enabled(60, false))
	testing.expect(t, !_frame_pacing_enabled(60, true))
	testing.expect(t, !_frame_pacing_enabled(0, false))
	testing.expect(t, !_frame_pacing_enabled(-1, false))
}

when ODIN_OS != .Windows || INGOT_GFX_EXPECTED_ASSERTS {
	@(test)
	frame_owner_rejects_stale_epoch :: proc(t: ^testing.T) {
		frame_owner_test_context.epoch = 7
		frame := Frame {
			owner     = &frame_owner_test_context,
			epoch     = 7,
			open      = true,
			available = true,
		}
		testing.expect(t, frame_owner(&frame) == &frame_owner_test_context)
		frame_owner_test_context.epoch += 1
		testing.expect_assert_message(t, "frame_owner: stale owner")
		_ = frame_owner(&frame)
		testing.fail_now(t, "frame_owner accepted a stale context epoch")
	}
}

@(test)
frame_availability_requires_open_available_frame :: proc(t: ^testing.T) {
	ctx := new(Context)
	defer free(ctx)
	frame: Frame
	testing.expect(t, !frame_available(&frame))
	frame.owner = ctx
	frame.open = true
	testing.expect(t, !frame_available(&frame))
	frame.available = true
	testing.expect(t, frame_available(&frame))
}

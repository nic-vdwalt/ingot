#+build !js
package gfx

import "core:testing"

@(test)
frame_validation_rejects_stale_generation :: proc(t: ^testing.T) {
	old_epoch := g.epoch
	old_generation := g.frame_generation
	old_active := g.frame_active
	defer {
		g.epoch = old_epoch
		g.frame_generation = old_generation
		g.frame_active = old_active
	}

	g.epoch = 2
	g.frame_generation = 4
	g.frame_active = true
	frame := Frame {
		owner      = &default_context_storage,
		epoch      = 2,
		generation = 3,
		active     = true,
	}
	testing.expect(t, !_frame_valid(&frame))
}

@(test)
frame_validation_rejects_inactive_frame :: proc(t: ^testing.T) {
	old_epoch := g.epoch
	old_generation := g.frame_generation
	old_active := g.frame_active
	defer {
		g.epoch = old_epoch
		g.frame_generation = old_generation
		g.frame_active = old_active
	}

	g.epoch = 2
	g.frame_generation = 4
	g.frame_active = true
	frame := Frame {
		owner      = &default_context_storage,
		epoch      = 2,
		generation = 4,
		active     = false,
	}
	testing.expect(t, !_frame_valid(&frame))
}

@(test)
frame_validation_routes_independent_contexts :: proc(t: ^testing.T) {
	first := new(Context)
	second := new(Context)
	defer free(first)
	defer free(second)
	first.id, first.epoch, first.frame_generation, first.frame_active = 2, 4, 7, true
	second.id, second.epoch, second.frame_generation, second.frame_active = 3, 5, 9, true
	first.frame.has_frame = true
	second.frame.has_frame = true
	first_frame := Frame {
		owner      = first,
		epoch      = 4,
		generation = 7,
		active     = true,
	}
	second_frame := Frame {
		owner      = second,
		epoch      = 5,
		generation = 9,
		active     = true,
	}
	testing.expect(t, _frame_valid(&first_frame))
	testing.expect(t, _frame_valid(&second_frame))
	first_frame.owner = second
	testing.expect(t, !_frame_valid(&first_frame))
}

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
context_scope_routes_convenience_queries_and_restores_default :: proc(t: ^testing.T) {
	ctx := new(Context)
	defer free(ctx)
	default_width := default_context_storage.width
	default_mouse := default_context_storage.inp.mouse
	default_pressed := default_context_storage.inp.pressed[KeyboardKey.A]
	default_key_down := default_context_storage.inp.key_down[KeyboardKey.A]
	default_mouse_down := default_context_storage.inp.mb_down[MouseButton.LEFT]
	defer {
		default_context_storage.width = default_width
		default_context_storage.inp.mouse = default_mouse
		default_context_storage.inp.pressed[KeyboardKey.A] = default_pressed
		default_context_storage.inp.key_down[KeyboardKey.A] = default_key_down
		default_context_storage.inp.mb_down[MouseButton.LEFT] = default_mouse_down
	}
	default_context_storage.width = 640
	default_context_storage.inp.mouse = {10, 20}
	default_context_storage.inp.pressed[KeyboardKey.A] = false
	default_context_storage.inp.key_down[KeyboardKey.A] = false
	default_context_storage.inp.mb_down[MouseButton.LEFT] = false
	ctx.width = 320
	ctx.inp.mouse = {30, 40}
	ctx.inp.pressed[KeyboardKey.A] = true
	ctx.inp.key_down[KeyboardKey.A] = true
	ctx.inp.mb_down[MouseButton.LEFT] = true
	testing.expect_value(t, GetScreenWidth(), i32(640))
	testing.expect_value(t, GetMousePosition(), Vector2{10, 20})
	testing.expect(t, !IsKeyPressed(.A))
	testing.expect(t, !IsKeyDown(.A))
	testing.expect(t, !IsMouseButtonDown(.LEFT))
	scope := context_scope_enter(ctx)
	testing.expect_value(t, GetScreenWidth(), i32(320))
	testing.expect_value(t, GetMousePosition(), Vector2{30, 40})
	testing.expect(t, IsKeyPressed(.A))
	testing.expect(t, IsKeyDown(.A))
	testing.expect(t, IsMouseButtonDown(.LEFT))
	context_scope_leave(&scope)
	testing.expect_value(t, GetScreenWidth(), i32(640))
	testing.expect_value(t, GetMousePosition(), Vector2{10, 20})
	testing.expect(t, !IsKeyPressed(.A))
	testing.expect(t, !IsKeyDown(.A))
	testing.expect(t, !IsMouseButtonDown(.LEFT))
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

// --- surface mixing guard --------------------------------------------------
// gfx exposes two drawing surfaces over one renderer. A raylib-shaped draw
// acts on the globally active context; an ergonomic draw activates its
// Frame's owner first. Interleaving them across contexts silently sends
// geometry to the wrong window, so batch_set consults this predicate.

@(test)
surface_routing_allows_single_context_mixing :: proc(t: ^testing.T) {
	// ui_gfx paints by calling raylib-shaped procedures at top level inside
	// the ergonomic frame it opened on the default context. That is the
	// common case and must stay allowed.
	testing.expect(t, !_surface_routing_is_ambiguous(0, 1, true))
}

@(test)
surface_routing_allows_plain_raylib_style :: proc(t: ^testing.T) {
	// BeginDrawing/EndDrawing with no ergonomic frame anywhere.
	testing.expect(t, !_surface_routing_is_ambiguous(0, 0, false))
}

@(test)
surface_routing_exempts_ergonomic_wrappers :: proc(t: ^testing.T) {
	// Inside draw_rect and friends the owner is activated, so the draw is
	// routed correctly even while another context holds a frame.
	testing.expect(t, !_surface_routing_is_ambiguous(1, 2, true))
	testing.expect(t, !_surface_routing_is_ambiguous(1, 2, false))
}

@(test)
surface_routing_rejects_draw_aimed_at_wrong_context :: proc(t: ^testing.T) {
	// A frame is open on another context and the active one has none: the
	// draw cannot reach the frame its caller meant.
	testing.expect(t, _surface_routing_is_ambiguous(0, 1, false))
}

@(test)
surface_routing_rejects_interleaved_frames :: proc(t: ^testing.T) {
	// Two contexts hold frames at once; a top-level draw is ambiguous even
	// though the active context has one of them.
	testing.expect(t, _surface_routing_is_ambiguous(0, 2, true))
}

@(test)
surface_routing_counters_balance_across_a_frame :: proc(t: ^testing.T) {
	depth_before := context_activation_depth
	frames_before := ergonomic_frames_active

	ctx := new(Context)
	defer free(ctx)
	ctx.id, ctx.epoch = 2, 4

	previous := _context_activate(ctx)
	testing.expect_value(t, context_activation_depth, depth_before + 1)
	_context_restore(previous)
	testing.expect_value(t, context_activation_depth, depth_before)
	testing.expect_value(t, previous, default_context())

	ctx.frame_active = true
	_ergonomic_frame_opened(ctx)
	testing.expect_value(t, ergonomic_frames_active, frames_before + 1)
	testing.expect(t, _surface_routing_is_ambiguous(0, ergonomic_frames_active, false))

	ctx.frame_active = false
	_ergonomic_frame_closed(ctx)
	testing.expect_value(t, ergonomic_frames_active, frames_before)
}

#+build !js
package gfx

import "core:testing"

@(test)
gpu_timing_geometry_failure_keeps_draw_inputs :: proc(t: ^testing.T) {
	when GPU_TIMING_DIAGNOSTICS {
		ctx := new(Context)
		defer free(ctx)
		state := &ctx.gpu_timing.diagnostics[0]
		encoder := cast(type_of(state.bindings[0][0].encoder))uintptr(1)
		pass := cast(type_of(state.bindings[0][0].pass))uintptr(2)
		ctx.frame.pass = pass
		ctx.rend.diagnostic_projection = _window_projection(1280, 720)
		append(&ctx.rend.verts, Vertex{pos = {11, 23}})
		append(&ctx.rend.indices, u32(0))
		_gpu_timing_diagnostic_encoder_created(state, encoder)
		_gpu_timing_diagnostic_bind(state, 0, 0, encoder, pass, .Clear, .Store)
		_gpu_timing_diagnostic_batch_draw(ctx, &ctx.rend, pass, 1)
		clear(&ctx.rend.verts)
		clear(&ctx.rend.indices)
		_gpu_timing_diagnostic_submit(state, encoder)
		slot := &ctx.gpu_timing.slots[0]
		slot.query_count = 2
		slot.ticks[0], slot.ticks[1] = 123, 0
		_gpu_timing_diagnostic_collect(ctx, 0)
		testing.expect_value(t, state.failure_count, u32(1))
		draw := state.failures[0].draws[0]
		testing.expect_value(t, draw.geometry_id, u32(1))
		testing.expect_value(t, draw.projection, _window_projection(1280, 720))
		testing.expect_value(
			t,
			state.geometry[draw.geometry_id - 1].vertices[0].pos,
			[2]f32{11, 23},
		)
		testing.expect_value(t, state.geometry[draw.geometry_id - 1].index_count, u32(1))
	}
}

@(test)
gpu_timing_geometry_identifies_only_explicit_neutral_texture :: proc(t: ^testing.T) {
	when GPU_TIMING_DIAGNOSTICS {
		ctx := new(Context)
		defer free(ctx)
		state := &ctx.gpu_timing.diagnostics[0]
		encoder := cast(type_of(state.bindings[0][0].encoder))uintptr(1)
		pass := cast(type_of(state.bindings[0][0].pass))uintptr(2)
		ctx.frame.pass = pass
		ctx.rend.neutral_bind = cast(type_of(ctx.rend.cur_bind))uintptr(3)
		_gpu_timing_diagnostic_encoder_created(state, encoder)
		_gpu_timing_diagnostic_bind(state, 0, 0, encoder, pass, .Clear, .Store)
		_gpu_timing_diagnostic_batch_draw(ctx, &ctx.rend, pass, 0)
		ctx.rend.cur_bind = ctx.rend.neutral_bind
		_gpu_timing_diagnostic_batch_draw(ctx, &ctx.rend, pass, 0)
		ctx.rend.cur_bind = cast(type_of(ctx.rend.cur_bind))uintptr(4)
		_gpu_timing_diagnostic_batch_draw(ctx, &ctx.rend, pass, 0)
		_gpu_timing_diagnostic_submit(state, encoder)
		slot := &ctx.gpu_timing.slots[0]
		slot.query_count = 2
		slot.ticks[0], slot.ticks[1] = 123, 0
		_gpu_timing_diagnostic_collect(ctx, 0)
		testing.expect_value(t, state.failure_count, u32(1))
		testing.expect(t, !state.failures[0].draws[0].neutral_texture)
		testing.expect(t, state.failures[0].draws[1].neutral_texture)
		testing.expect(t, !state.failures[0].draws[2].neutral_texture)
	}
}

@(test)
gpu_timing_geometry_only_retains_linked_draws :: proc(t: ^testing.T) {
	when GPU_TIMING_DIAGNOSTICS {
		ctx := new(Context)
		defer free(ctx)
		state := &ctx.gpu_timing.diagnostics[0]
		encoder := cast(type_of(state.bindings[0][0].encoder))uintptr(1)
		pass := cast(type_of(state.bindings[0][0].pass))uintptr(2)
		ctx.frame.pass = pass
		append(&ctx.rend.verts, Vertex{pos = {1, 2}})
		append(&ctx.rend.indices, u32(0))
		_gpu_timing_diagnostic_batch_draw(ctx, &ctx.rend, pass, 1)
		testing.expect_value(t, state.geometry_count, u32(0))
		_gpu_timing_diagnostic_encoder_created(state, encoder)
		_gpu_timing_diagnostic_bind(state, 0, 0, encoder, pass, .Clear, .Store)
		_gpu_timing_diagnostic_batch_draw(ctx, &ctx.rend, pass, 2)
		testing.expect_value(t, state.geometry_count, u32(0))
		testing.expect_value(t, state.geometry_dropped, u64(1))
		for _ in 1 ..< GPU_TIMING_DIAGNOSTIC_DRAWS_PER_PASS {
			_gpu_timing_diagnostic_batch_draw(ctx, &ctx.rend, pass, 1)
		}
		_gpu_timing_diagnostic_batch_draw(ctx, &ctx.rend, pass, 1)
		testing.expect_value(t, state.geometry_count, u32(3))
		testing.expect_value(t, state.geometry_dropped, u64(1))
		testing.expect_value(t, state.bindings[0][0].record.draws_dropped, u32(1))
		_gpu_timing_diagnostic_submit(state, encoder)
		_gpu_timing_diagnostic_batch_draw(ctx, &ctx.rend, pass, 1)
		testing.expect_value(t, state.geometry_count, u32(3))
	}
}

@(test)
gpu_timing_geometry_is_owned_and_bounded :: proc(t: ^testing.T) {
	state := new(Gpu_Timing_Diagnostics)
	defer free(state)
	vertices := [1]Vertex{{pos = {1, 2}}}
	indices := [1]u32{0}
	identity := _gpu_timing_diagnostic_geometry(state, vertices[:], indices[:])
	testing.expect_value(t, identity, u32(1))
	vertices[0].pos[0] = 99
	indices[0] = 99
	testing.expect_value(t, state.geometry[0].vertices[0].pos[0], f32(1))
	testing.expect_value(t, state.geometry[0].indices[0], u32(0))
	for _ in 1 ..< GPU_TIMING_DIAGNOSTIC_GEOMETRY_CAPACITY {
		_ = _gpu_timing_diagnostic_geometry(state, vertices[:], indices[:])
	}
	testing.expect_value(
		t,
		_gpu_timing_diagnostic_geometry(state, vertices[:], indices[:]),
		u32(0),
	)
	testing.expect_value(t, state.geometry_dropped, u64(1))
	testing.expect_value(t, state.geometry_count, u32(GPU_TIMING_DIAGNOSTIC_GEOMETRY_CAPACITY))
}

@(test)
gpu_timing_geometry_rejects_oversized_without_partial_copy :: proc(t: ^testing.T) {
	state := new(Gpu_Timing_Diagnostics)
	defer free(state)
	vertices := make([]Vertex, GPU_TIMING_DIAGNOSTIC_VERTICES_MAX + 1)
	defer delete(vertices)
	indices := make([]u32, GPU_TIMING_DIAGNOSTIC_INDICES_MAX + 1)
	defer delete(indices)
	testing.expect_value(t, _gpu_timing_diagnostic_geometry(state, vertices, indices[:1]), u32(0))
	testing.expect_value(t, _gpu_timing_diagnostic_geometry(state, vertices[:1], indices), u32(0))
	testing.expect_value(t, _gpu_timing_diagnostic_geometry(state, nil, indices[:1]), u32(0))
	testing.expect_value(t, state.geometry_count, u32(0))
	testing.expect_value(t, state.geometry_dropped, u64(3))
	testing.expect_value(t, state.geometry[0].vertex_count, u32(0))
}

@(test)
gpu_timing_geometry_copy_out_survives_reset :: proc(t: ^testing.T) {
	when GPU_TIMING_DIAGNOSTICS {
		ctx := new(Context)
		defer free(ctx)
		state := &ctx.gpu_timing.diagnostics[0]
		vertices := [1]Vertex{{pos = {3, 4}}}
		indices := [1]u32{0}
		_ = _gpu_timing_diagnostic_geometry(state, vertices[:], indices[:])
		output := make([]Gpu_Timing_Diagnostic_Geometry, 1)
		defer delete(output)
		testing.expect_value(t, context_gpu_timing_diagnostic_geometry(ctx, output), u32(1))
		testing.expect_value(t, context_gpu_timing_diagnostic_geometry(ctx, nil), u32(0))
		state^ = {}
		testing.expect_value(t, output[0].vertices[0].pos, [2]f32{3, 4})
		testing.expect_value(t, output[0].vertex_count, u32(1))
	}
}

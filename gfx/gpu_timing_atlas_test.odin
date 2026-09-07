#+build !js
package gfx

import "core:testing"

@(test)
gpu_timing_atlas_uploads_are_owned_and_bounded :: proc(t: ^testing.T) {
	state := new(Gpu_Timing_Atlas_Evidence)
	defer free(state)
	state.atlas_count = 1
	pixels := [8]u8{1, 2, 99, 99, 3, 4, 99, 99}
	_gpu_timing_atlas_upload(state, 1, 7, 9, 2, 2, 4, pixels[:])
	pixels = {}
	testing.expect_value(t, state.byte_count, u32(4))
	testing.expect_value(t, state.upload_count, u32(1))
	expected_bytes := [4]u8{1, 2, 3, 4}
	for expected, index in expected_bytes {
		testing.expect_value(t, state.bytes[index], expected)
	}
	testing.expect_value(t, state.uploads[0].x, u32(7))
	for _ in 1 ..< GPU_TIMING_ATLAS_UPLOADS_MAX {
		_gpu_timing_atlas_upload(state, 1, 0, 0, 1, 1, 1, pixels[:])
	}
	_gpu_timing_atlas_upload(state, 1, 0, 0, 1, 1, 1, pixels[:])
	testing.expect_value(t, state.dropped, u64(1))
	testing.expect_value(t, state.dropped_bytes, u64(1))
	state^ = {
		atlas_count = 1,
		byte_count  = GPU_TIMING_ATLAS_BYTES_MAX,
	}
	_gpu_timing_atlas_upload(state, 1, 0, 0, 1, 1, 1, pixels[:])
	testing.expect_value(t, state.upload_count, u32(0))
	testing.expect_value(t, state.dropped, u64(1))
	testing.expect_value(t, state.dropped_bytes, u64(1))
	state^ = {
		atlas_count = 1,
	}
	_gpu_timing_atlas_upload(state, 1, ATLAS_DIM, 0, 1, 1, 1, pixels[:])
	_gpu_timing_atlas_upload(state, 1, 0, 0, 2, 2, 1, pixels[:])
	_gpu_timing_atlas_upload(state, 1, 0, 0, 2, 2, 4, pixels[:2])
	_gpu_timing_atlas_upload(state, 2, 0, 0, 1, 1, 1, pixels[:])
	testing.expect_value(t, state.dropped, u64(4))
	testing.expect_value(t, state.dropped_bytes, u64(1 + 4 + 4 + 1))
	testing.expect_value(t, state.byte_count, u32(0))
}

@(test)
gpu_timing_atlas_submit_seals_upload_prefix :: proc(t: ^testing.T) {
	when GPU_TIMING_DIAGNOSTICS {
		state := new(Gpu_Timing_Diagnostics)
		defer free(state)
		encoder := cast(type_of(state.bindings[0][0].encoder))uintptr(1)
		pass := cast(type_of(state.bindings[0][0].pass))uintptr(2)
		_gpu_timing_diagnostic_encoder_created(state, encoder)
		_gpu_timing_diagnostic_bind(state, 0, 0, encoder, pass, .Clear, .Store)
		_gpu_timing_diagnostic_draw(
			state,
			pass,
			{atlas_id = 1, atlas_upload_count = 1, atlas_known = true},
		)
		state.atlas.upload_count = 3
		_gpu_timing_diagnostic_submit(state, encoder)
		testing.expect_value(t, state.bindings[0][0].record.draws[0].atlas_upload_count, u32(3))
		testing.expect(t, state.bindings[0][0].record.draws[0].atlas_known)
		_gpu_timing_diagnostic_encoder_created(state, encoder)
		_gpu_timing_diagnostic_bind(state, 1, 0, encoder, pass, .Clear, .Store)
		_gpu_timing_diagnostic_draw(state, pass, {atlas_id = 1, atlas_known = true})
		state.atlas.dropped = 1
		_gpu_timing_diagnostic_submit(state, encoder)
		testing.expect(t, !state.bindings[1][0].record.draws[0].atlas_known)
		testing.expect(t, state.bindings[0][0].record.draws[0].atlas_known)
	}
}

@(test)
gpu_timing_atlas_failure_keeps_submitted_inputs :: proc(t: ^testing.T) {
	when GPU_TIMING_DIAGNOSTICS {
		cases := [2]bool{false, true}
		for lose_upload in cases {
			ctx := new(Context)
			defer free(ctx)
			state := &ctx.gpu_timing.diagnostics[0]
			atlas: Atlas
			atlas.bind = cast(type_of(atlas.bind))uintptr(3)
			atlas.diagnostic_id[0] = 1
			atlas.filter = .POINT
			ctx.resources.atlases.slots[0] = {occupied = true, entry = &atlas}
			ctx.rend.cur_bind = atlas.bind
			state.atlas.atlas_count = 1
			pixels := [1]u8{127}
			_gpu_timing_atlas_upload(&state.atlas, 1, 0, 0, 1, 1, 1, pixels[:])
			encoder := cast(type_of(state.bindings[0][0].encoder))uintptr(1)
			pass := cast(type_of(state.bindings[0][0].pass))uintptr(2)
			ctx.frame.pass = pass
			ctx.rend.diagnostic_projection = _window_projection(1280, 720)
			append(&ctx.rend.verts, Vertex{pos = {11, 23}, mode = .Text})
			append(&ctx.rend.indices, u32(0))
			_gpu_timing_diagnostic_encoder_created(state, encoder)
			_gpu_timing_diagnostic_bind(state, 0, 0, encoder, pass, .Clear, .Store)
			_gpu_timing_diagnostic_batch_draw(ctx, &ctx.rend, pass, 1)
			clear(&ctx.rend.verts)
			clear(&ctx.rend.indices)
			pixels[0] = 255
			x := u32(0)
			if lose_upload do x = ATLAS_DIM
			_gpu_timing_atlas_upload(&state.atlas, 1, x, 0, 1, 1, 1, pixels[:])
			_gpu_timing_diagnostic_submit(state, encoder)
			pixels[0] = 64
			_gpu_timing_atlas_upload(&state.atlas, 1, 0, 0, 1, 1, 1, pixels[:])
			slot := &ctx.gpu_timing.slots[0]
			slot.query_count = 2
			slot.ticks[0], slot.ticks[1] = 123, 0
			_gpu_timing_diagnostic_collect(ctx, 0)
			testing.expect_value(t, state.failure_count, u32(1))
			draw := state.failures[0].draws[0]
			testing.expect_value(t, draw.geometry_id, u32(1))
			testing.expect_value(t, draw.atlas_id, u32(1))
			testing.expect_value(t, draw.atlas_known, !lose_upload)
			expected_prefix := u32(2)
			if lose_upload do expected_prefix = 1
			testing.expect_value(t, draw.atlas_upload_count, expected_prefix)
			testing.expect_value(t, draw.atlas_filter, u32(TextureFilter.POINT))
			testing.expect_value(t, state.atlas.bytes[0], u8(127))
			testing.expect_value(t, state.geometry[0].vertices[0].mode, Vertex_Mode.Text)
		}
	}
}

@(test)
gpu_timing_atlas_draw_tracks_upload_prefix :: proc(t: ^testing.T) {
	when GPU_TIMING_DIAGNOSTICS {
		ctx := new(Context)
		defer free(ctx)
		atlas: Atlas
		atlas.bind = cast(type_of(atlas.bind))uintptr(1)
		atlas.diagnostic_id[0] = 1
		atlas.filter = .POINT
		ctx.resources.atlases.slots[0] = {
			occupied = true,
			entry    = &atlas,
		}
		ctx.rend.cur_bind = atlas.bind
		state := &ctx.gpu_timing.diagnostics[0].atlas
		state.atlas_count = 1
		pixels := [1]u8{127}
		_gpu_timing_atlas_upload(state, 1, 0, 0, 1, 1, 1, pixels[:])
		identity, prefix, filter, known := _gpu_timing_atlas_draw(ctx, &ctx.rend)
		testing.expect_value(t, identity, u32(1))
		testing.expect_value(t, prefix, u32(1))
		testing.expect_value(t, filter, u32(TextureFilter.POINT))
		testing.expect(t, known)
		output := new(Gpu_Timing_Atlas_Evidence)
		defer free(output)
		context_gpu_timing_atlas_evidence(ctx, output)
		state^ = {}
		testing.expect_value(t, output.bytes[0], u8(127))
		_, _, _, unknown := _gpu_timing_atlas_draw(ctx, &ctx.rend)
		testing.expect(t, !unknown)
	}
}

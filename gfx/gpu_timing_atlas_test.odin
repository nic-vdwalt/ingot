#+build !js
package gfx

import "core:testing"
import wg "vendor:wgpu"

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
	state^ = {
		atlas_count = 1,
		byte_count  = GPU_TIMING_ATLAS_BYTES_MAX,
	}
	_gpu_timing_atlas_upload(state, 1, 0, 0, 1, 1, 1, pixels[:])
	testing.expect_value(t, state.upload_count, u32(0))
	testing.expect_value(t, state.dropped, u64(1))
	state^ = {
		atlas_count = 1,
	}
	_gpu_timing_atlas_upload(state, 1, ATLAS_DIM, 0, 1, 1, 1, pixels[:])
	_gpu_timing_atlas_upload(state, 1, 0, 0, 2, 2, 1, pixels[:])
	_gpu_timing_atlas_upload(state, 1, 0, 0, 2, 2, 4, pixels[:2])
	_gpu_timing_atlas_upload(state, 2, 0, 0, 1, 1, 1, pixels[:])
	testing.expect_value(t, state.dropped, u64(4))
	testing.expect_value(t, state.byte_count, u32(0))
}

@(test)
gpu_timing_atlas_submit_seals_upload_prefix :: proc(t: ^testing.T) {
	when GPU_TIMING_DIAGNOSTICS {
		state := new(Gpu_Timing_Diagnostics)
		defer free(state)
		encoder := cast(wg.CommandEncoder)uintptr(1)
		pass := cast(wg.RenderPassEncoder)uintptr(2)
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
gpu_timing_atlas_draw_tracks_upload_prefix :: proc(t: ^testing.T) {
	when GPU_TIMING_DIAGNOSTICS {
		ctx := new(Context)
		defer free(ctx)
		atlas: Atlas
		atlas.bind = cast(wg.BindGroup)uintptr(1)
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

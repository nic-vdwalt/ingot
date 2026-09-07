package gfx

// GPU_TIMING_ATLAS_UPLOADS_MAX must cover every atlas upload that precedes the
// first retained window failure, or no draw's texture prefix is known. The v6
// loading-inclusive PlanetForger capture at 2560x1440 recorded 1738 uploads
// (256 kept + 1482 dropped) with the earlier 256 bound, dropping before the
// first frame; 2048 covers that measurement with headroom at 28 bytes per
// record. GPU_TIMING_ATLAS_BYTES_MAX stays 1 MiB: the retained 256 uploads
// averaged 333 bytes, and dropped_bytes now reports whether it ever binds.
GPU_TIMING_ATLAS_UPLOADS_MAX :: 2048
GPU_TIMING_ATLAS_BYTES_MAX :: 1024 * 1024

Gpu_Timing_Atlas_Upload :: struct {
	atlas_id:                u32,
	x, y, width, height:     u32,
	byte_offset, byte_count: u32,
}

Gpu_Timing_Atlas_Evidence :: struct {
	atlas_count:   u32,
	upload_count:  u32,
	byte_count:    u32,
	dropped:       u64,
	// Pixel bytes the dropped uploads would have retained, so the byte budget
	// can be sized from a capture instead of guessed.
	dropped_bytes: u64,
	uploads:       [GPU_TIMING_ATLAS_UPLOADS_MAX]Gpu_Timing_Atlas_Upload,
	bytes:         [GPU_TIMING_ATLAS_BYTES_MAX]u8,
}

context_gpu_timing_atlas_evidence :: proc(ctx: ^Context, output: ^Gpu_Timing_Atlas_Evidence) {
	assert(ctx != nil)
	assert(output != nil)
	when GPU_TIMING_DIAGNOSTICS {
		output^ = ctx.gpu_timing.diagnostics[0].atlas
	} else {
		output^ = {}
	}
}

_gpu_timing_atlas_draw :: proc(ctx: ^Context, renderer: ^Renderer) -> (u32, u32, u32, bool) {
	assert(ctx != nil)
	assert(renderer != nil)
	when GPU_TIMING_DIAGNOSTICS {
		state := &ctx.gpu_timing.diagnostics[0].atlas
		for slot in ctx.resources.atlases.slots {
			if !slot.occupied || slot.entry == nil do continue
			atlas := slot.entry
			if atlas.bind != nil && atlas.bind == renderer.cur_bind {
				return atlas.diagnostic_id[0],
					state.upload_count,
					u32(atlas.filter),
					state.dropped == 0 &&
					atlas.diagnostic_id[0] != 0 &&
					atlas.diagnostic_id[0] <= state.atlas_count
			}
		}
	}
	return 0, 0, 0, false
}

_gpu_timing_atlas_upload :: proc(
	state: ^Gpu_Timing_Atlas_Evidence,
	atlas_id, x, y, width, height, stride: u32,
	pixels: []u8,
) {
	assert(state != nil)
	assert(state.upload_count <= GPU_TIMING_ATLAS_UPLOADS_MAX)
	assert(state.byte_count <= GPU_TIMING_ATLAS_BYTES_MAX)
	byte_count := u64(width) * u64(height)
	if atlas_id == 0 ||
	   atlas_id > state.atlas_count ||
	   width == 0 ||
	   height == 0 ||
	   u64(x) + u64(width) > ATLAS_DIM ||
	   u64(y) + u64(height) > ATLAS_DIM ||
	   stride < width ||
	   u64(stride) * u64(height) > u64(len(pixels)) ||
	   state.upload_count == GPU_TIMING_ATLAS_UPLOADS_MAX ||
	   byte_count > u64(GPU_TIMING_ATLAS_BYTES_MAX - state.byte_count) {
		state.dropped += 1
		state.dropped_bytes += byte_count
		return
	}
	state.uploads[state.upload_count] = {
		atlas_id    = atlas_id,
		x           = x,
		y           = y,
		width       = width,
		height      = height,
		byte_offset = state.byte_count,
		byte_count  = u32(byte_count),
	}
	for row in 0 ..< height {
		source_offset := u64(row) * u64(stride)
		target_offset := state.byte_count + row * width
		copy(
			state.bytes[target_offset:target_offset + width],
			pixels[source_offset:source_offset + u64(width)],
		)
	}
	state.byte_count += u32(byte_count)
	state.upload_count += 1
}

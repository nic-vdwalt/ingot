package gfx

import wg "vendor:wgpu"

RENDER_STATS_ENABLED :: #config(INGOT_RENDER_STATS, false)

// Flush_Cause tags why a batch flush (== one draw call) happened, so hosts
// can see which state changes fragment their batches.
Flush_Cause :: enum u8 {
	Manual, // FlushBatch / rlgl VAO ordering / uncategorized
	Pipeline, // pipeline kind switch (solid <-> text <-> image)
	Texture, // texture bind-group switch within one pipeline
	Blend, // blend-mode switch
	Scissor, // Begin/EndScissorMode
	Matrix, // rlgl model-matrix pop/translate
	Target, // render-target begin/end
	Shader, // custom shader begin/end
	Frame_End, // end-of-frame flush in EndDrawing
}

Renderer_Stats :: struct {
	frame_index:                   u64,
	flush_count:                   u32,
	vertices_uploaded:             u64,
	indices_uploaded:              u64,
	bytes_uploaded:                u64,
	buffer_creations:              u32,
	buffer_growths:                u32,
	pipeline_switches:             u32,
	bind_group_switches:           u32,
	render_passes:                 u32,
	queue_submissions:             u32,
	peak_geometry_arena_bytes:     u64,
	peak_uniform_arena_bytes:      u64,
	geometry_reservation_failures: u32,
	uniform_reservation_failures:  u32,
	stream_slot_exhaustions:       u32,
	submission_tracking_failures:  u32,
	stream_retirement_failures:    u32,
	gpu3d_pool_exhaustions:        u32,
	composite_alpha_mode:          wg.CompositeAlphaMode,
	flush_causes:                  [Flush_Cause]u32,
}

renderer_stats :: proc() -> Renderer_Stats {
	return context_renderer_stats(default_context())
}

context_renderer_stats :: proc(ctx: ^Context) -> Renderer_Stats {
	if ctx == nil do return {}
	when RENDER_STATS_ENABLED {
		if ctx.frame.has_frame do return ctx.stats_current
	}
	return ctx.stats_latest
}

renderer_stats_reset :: proc() {
	context_renderer_stats_reset(default_context())
}

context_renderer_stats_reset :: proc(ctx: ^Context) {
	if ctx == nil do return
	when RENDER_STATS_ENABLED {
		alpha := ctx.stats_current.composite_alpha_mode
		index := ctx.stats_current.frame_index
		ctx.stats_current = {}
		ctx.stats_latest = {}
		ctx.stats_current.composite_alpha_mode = alpha
		ctx.stats_current.frame_index = index
	}
}

@(private)
_stats_frame_begin :: proc() {
	when RENDER_STATS_ENABLED {
		index := g.stats_current.frame_index + 1
		alpha := g.stats_current.composite_alpha_mode
		g.stats_current = {}
		g.stats_current.frame_index = index
		g.stats_current.composite_alpha_mode = alpha
	}
}

@(private)
_stats_frame_end :: proc() {
	when RENDER_STATS_ENABLED {
		g.stats_latest = g.stats_current
	}
}

@(private)
_stats_set_alpha_mode :: proc(mode: wg.CompositeAlphaMode) {
	when RENDER_STATS_ENABLED {
		g.stats_current.composite_alpha_mode = mode
		g.stats_latest.composite_alpha_mode = mode
	}
}

@(private)
_stats_flush :: proc(vertices, bytes: u64, cause: Flush_Cause) {
	when RENDER_STATS_ENABLED {
		g.stats_current.flush_count += 1
		g.stats_current.vertices_uploaded += vertices
		g.stats_current.bytes_uploaded += bytes
		g.stats_current.flush_causes[cause] += 1
	}
}

@(private)
_stats_buffer_created :: proc(growth: bool) {
	when RENDER_STATS_ENABLED {
		g.stats_current.buffer_creations += 1
		if growth do g.stats_current.buffer_growths += 1
	}
}

@(private)
_stats_pipeline_switch :: proc() {
	when RENDER_STATS_ENABLED {
		g.stats_current.pipeline_switches += 1
	}
}

@(private)
_stats_bind_group_switches :: proc(count: u32) {
	when RENDER_STATS_ENABLED {
		g.stats_current.bind_group_switches += count
	}
}

@(private)
_stats_render_pass :: proc() {
	when RENDER_STATS_ENABLED {
		g.stats_current.render_passes += 1
	}
}

@(private)
_stats_queue_submission :: proc() {
	when RENDER_STATS_ENABLED {
		g.stats_current.queue_submissions += 1
	}
}

@(private)
_stats_reservation_failure :: proc(uniform: bool) {
	when RENDER_STATS_ENABLED {
		if uniform {
			g.stats_current.uniform_reservation_failures += 1
		} else {
			g.stats_current.geometry_reservation_failures += 1
		}
	}
}

@(private)
_stats_stream_slot_exhaustion :: proc() {
	when RENDER_STATS_ENABLED {
		g.stats_current.stream_slot_exhaustions += 1
	}
}

// _stats_gpu3d_pool_exhaustion counts GPU-3D fixed-pool exhaustion (mesh or
// pipeline slots) so hosts can see why 3D draws stopped appearing.
@(private)
_stats_gpu3d_pool_exhaustion :: proc() {
	when RENDER_STATS_ENABLED {
		g.stats_current.gpu3d_pool_exhaustions += 1
	}
}

@(private)
_stats_submission_tracking_failure :: proc() {
	when RENDER_STATS_ENABLED {
		g.stats_current.submission_tracking_failures += 1
	}
}

@(private)
_stats_stream_retirement_failure :: proc() {
	when RENDER_STATS_ENABLED {
		g.stats_current.stream_retirement_failures += 1
	}
}

package gfx

import wg "vendor:wgpu"

RENDER_STATS_ENABLED :: #config(INGOT_RENDER_STATS, false)

// Flush_Cause tags why a batch flush (== one draw call) happened, so hosts
// can see which state changes fragment their batches.
Flush_Cause :: enum u8 {
	Manual, // FlushBatch / rlgl VAO ordering / uncategorized
	Pipeline, // pipeline kind switch (unified UI <-> image)
	Texture, // font atlas or image bind-group switch within one pipeline
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
	gpu3d_scene_bind_creations:    u32,
	render_passes:                 u32,
	queue_submissions:             u32,
	frame_cpu_seconds:             f64,
	acquire_cpu_seconds:           f64,
	encode_cpu_seconds:            f64,
	submit_cpu_seconds:            f64,
	present_cpu_seconds:           f64,
	peak_geometry_arena_bytes:     u64,
	peak_uniform_arena_bytes:      u64,
	stream_geometry_write_calls:   u32,
	stream_uniform_write_calls:    u32,
	stream_geometry_write_bytes:   u64,
	stream_uniform_write_bytes:    u64,
	stream_copy_cpu_seconds:       f64,
	stream_write_cpu_seconds:      f64,
	geometry_reservation_failures: u32,
	uniform_reservation_failures:  u32,
	stream_slot_exhaustions:       u32,
	submission_tracking_failures:  u32,
	stream_retirement_failures:    u32,
	gpu3d_pool_exhaustions:        u32,
	gpu3d_mesh_uploads:            u32,
	gpu3d_mesh_upload_bytes:       u64,
	gpu3d_draws:                   u32,
	gpu3d_instanced_draws:         u32,
	gpu3d_vertices_resident:       u64,
	gpu3d_vertices_drawn:          u64,
	gpu3d_indices_drawn:           u64,
	composite_alpha_mode:          wg.CompositeAlphaMode,
	flush_causes:                  [Flush_Cause]u32,
}

renderer_stats :: proc() -> Renderer_Stats {
	return context_renderer_stats(default_context())
}

renderer_stats_latest :: proc() -> Renderer_Stats {
	return context_renderer_stats_latest(default_context())
}

renderer_gpu_frame_timing :: proc() -> Gpu_Frame_Timing {
	return context_renderer_gpu_frame_timing(default_context())
}

context_renderer_gpu_frame_timing :: proc(ctx: ^Context) -> Gpu_Frame_Timing {
	if ctx == nil do return {}
	_gpu_timing_collect(ctx)
	return ctx.gpu_timing.latest
}

renderer_gpu_frame_timing_detail :: proc() -> Gpu_Frame_Timing_Detail {
	return context_renderer_gpu_frame_timing_detail(default_context())
}

context_renderer_gpu_frame_timing_detail :: proc(ctx: ^Context) -> Gpu_Frame_Timing_Detail {
	if ctx == nil do return {}
	_gpu_timing_collect(ctx)
	return ctx.gpu_timing.latest_detail
}

context_renderer_gpu_timing_drain :: proc(
	ctx: ^Context,
	output: []Gpu_Frame_Timing_Detail,
) -> (
	int,
	Gpu_Timing_Health,
) {
	if ctx == nil do return 0, {}
	_gpu_timing_collect(ctx)
	return _gpu_timing_drain(&ctx.gpu_timing, output)
}

gpu_timing_label_string :: proc(label: ^Gpu_Timing_Label) -> string {
	if label == nil do return ""
	length := min(int(label.length), GPU_TIMING_LABEL_MAX)
	return string(label.bytes[:length])
}

context_renderer_stats_latest :: proc(ctx: ^Context) -> Renderer_Stats {
	if ctx == nil do return {}
	return ctx.stats_latest
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

// Peak_Usage reports the largest batch this context has accumulated between
// flushes, against the capacities reserved for it. The capacities are static
// inline arrays (see BATCH_MAX_VERTICES), so the headroom reported here is
// memory that is always resident whether or not it is ever used - which makes
// this the measurement that justifies those numbers.
//
// Tracked unconditionally, unlike Renderer_Stats: capacity sizing must not
// depend on a build flag being set.
Peak_Usage :: struct {
	vertices:                int,
	vertices_capacity:       int,
	indices:                 int,
	indices_capacity:        int,
	geometry_stream_bytes:   u64,
	geometry_capacity_bytes: u64,
	uniform_stream_bytes:    u64,
	uniform_capacity_bytes:  u64,
}

renderer_peak_usage :: proc() -> Peak_Usage {
	return context_renderer_peak_usage(default_context())
}

context_renderer_peak_usage :: proc(ctx: ^Context) -> Peak_Usage {
	if ctx == nil do return {}
	assert(ctx.rend.peak_geometry_bytes <= ctx.rend.geometry_bytes)
	assert(ctx.rend.peak_uniform_bytes <= ctx.rend.uniform_bytes)
	return Peak_Usage {
		vertices = ctx.rend.peak_verts,
		vertices_capacity = BATCH_MAX_VERTICES,
		indices = ctx.rend.peak_indices,
		indices_capacity = BATCH_MAX_INDICES,
		geometry_stream_bytes = ctx.rend.peak_geometry_bytes,
		geometry_capacity_bytes = ctx.rend.geometry_bytes,
		uniform_stream_bytes = ctx.rend.peak_uniform_bytes,
		uniform_capacity_bytes = ctx.rend.uniform_bytes,
	}
}

@(private)
_stats_frame_begin :: proc(ctx: ^Context) {
	when RENDER_STATS_ENABLED {
		assert(ctx != nil, "_stats_frame_begin: nil context")
		_gpu_timing_collect(ctx)
		_stats_context_frame_begin(ctx)
		_gpu_timing_frame_begin(ctx)
		_stats_context_frame_started(ctx)
	}
}

@(private)
_stats_context_frame_started :: proc(ctx: ^Context) {
	when RENDER_STATS_ENABLED {
		assert(ctx != nil, "_stats_context_frame_started: nil context")
		ctx.stats_current.frame_cpu_seconds = platform_now()
	}
}

@(private)
_stats_context_frame_begin :: proc(ctx: ^Context) {
	when RENDER_STATS_ENABLED {
		assert(ctx != nil, "_stats_context_frame_begin: nil context")
		index := ctx.stats_current.frame_index + 1
		alpha := ctx.stats_current.composite_alpha_mode
		ctx.stats_current = {}
		ctx.stats_current.frame_index = index
		ctx.stats_current.composite_alpha_mode = alpha
	}
}

@(private)
_stats_frame_end :: proc(ctx: ^Context) {
	when RENDER_STATS_ENABLED {
		assert(ctx != nil, "_stats_frame_end: nil context")
		_stats_context_frame_stopped(ctx)
		_stats_context_frame_end(ctx)
	}
}

@(private)
_stats_context_frame_stopped :: proc(ctx: ^Context) {
	when RENDER_STATS_ENABLED {
		assert(ctx != nil, "_stats_context_frame_stopped: nil context")
		started := ctx.stats_current.frame_cpu_seconds
		ctx.stats_current.frame_cpu_seconds = platform_now() - started
	}
}

@(private)
_stats_context_frame_end :: proc(ctx: ^Context) {
	when RENDER_STATS_ENABLED {
		assert(ctx != nil, "_stats_context_frame_end: nil context")
		ctx.stats_latest = ctx.stats_current
	}
}

@(private)
_stats_set_alpha_mode :: proc(ctx: ^Context, mode: wg.CompositeAlphaMode) {
	when RENDER_STATS_ENABLED {
		assert(ctx != nil, "_stats_set_alpha_mode: nil context")
		ctx.stats_current.composite_alpha_mode = mode
		ctx.stats_latest.composite_alpha_mode = mode
	}
}

@(private)
_stats_flush :: proc(ctx: ^Context, vertices, bytes: u64, cause: Flush_Cause) {
	assert(cause >= min(Flush_Cause) && cause <= max(Flush_Cause))
	when RENDER_STATS_ENABLED {
		assert(ctx != nil, "_stats_flush: nil context")
		ctx.stats_current.flush_count += 1
		ctx.stats_current.vertices_uploaded += vertices
		ctx.stats_current.bytes_uploaded += bytes
		ctx.stats_current.flush_causes[cause] += 1
	}
}

@(private)
_stats_buffer_created :: proc(ctx: ^Context, growth: bool) {
	when RENDER_STATS_ENABLED {
		assert(ctx != nil, "_stats_buffer_created: nil context")
		ctx.stats_current.buffer_creations += 1
		if growth do ctx.stats_current.buffer_growths += 1
	}
}

@(private)
_stats_pipeline_switch :: proc(ctx: ^Context) {
	when RENDER_STATS_ENABLED {
		assert(ctx != nil, "_stats_pipeline_switch: nil context")
		ctx.stats_current.pipeline_switches += 1
	}
}

@(private)
_stats_bind_group_switches :: proc(ctx: ^Context, count: u32) {
	when RENDER_STATS_ENABLED {
		assert(ctx != nil, "_stats_bind_group_switches: nil context")
		ctx.stats_current.bind_group_switches += count
	}
}

@(private)
_stats_gpu3d_scene_bind_creation :: proc(ctx: ^Context) {
	when RENDER_STATS_ENABLED {
		assert(ctx != nil, "_stats_gpu3d_scene_bind_creation: nil context")
		ctx.stats_current.gpu3d_scene_bind_creations += 1
	}
}

@(private)
_stats_render_pass :: proc(ctx: ^Context) {
	when RENDER_STATS_ENABLED {
		assert(ctx != nil, "_stats_render_pass: nil context")
		ctx.stats_current.render_passes += 1
	}
}

@(private)
_stats_queue_submission :: proc(ctx: ^Context) {
	when RENDER_STATS_ENABLED {
		assert(ctx != nil, "_stats_queue_submission: nil context")
		ctx.stats_current.queue_submissions += 1
	}
}

@(private)
_stats_context_cpu_times :: proc(ctx: ^Context, frame, acquire, encode, submit, present: f64) {
	when RENDER_STATS_ENABLED {
		assert(ctx != nil, "_stats_context_cpu_times: nil context")
		assert(frame >= 0 && acquire >= 0, "_stats_context_cpu_times: negative frame time")
		assert(encode >= 0, "_stats_context_cpu_times: negative encode time")
		assert(submit >= 0 && present >= 0, "_stats_context_cpu_times: negative queue time")
		ctx.stats_current.frame_cpu_seconds += frame
		ctx.stats_current.acquire_cpu_seconds += acquire
		ctx.stats_current.encode_cpu_seconds += encode
		ctx.stats_current.submit_cpu_seconds += submit
		ctx.stats_current.present_cpu_seconds += present
	}
}

@(private)
_stats_finish_submit :: proc(
	ctx: ^Context,
	encoder: wg.CommandEncoder,
	allow_submit: bool,
) -> (
	cmd: wg.CommandBuffer,
	encode, submit: f64,
) {
	assert(ctx != nil && encoder != nil, "_stats_finish_submit: invalid argument")
	when RENDER_STATS_ENABLED {
		encode_started := platform_now()
		cmd = wg.CommandEncoderFinish(encoder, nil)
		encode = platform_now() - encode_started
		if allow_submit && cmd != nil {
			submit_started := platform_now()
			wg.QueueSubmit(ctx.queue, {cmd})
			when GPU_TIMING_DIAGNOSTICS {
				_gpu_timing_diagnostic_submit(&ctx.gpu_timing.diagnostics[0], encoder)
			}
			submit = platform_now() - submit_started
		} else {
			when GPU_TIMING_DIAGNOSTICS {
				_gpu_timing_diagnostic_encoder_retire(&ctx.gpu_timing.diagnostics[0], encoder)
			}
		}
	} else {
		cmd = wg.CommandEncoderFinish(encoder, nil)
		if allow_submit && cmd != nil do wg.QueueSubmit(ctx.queue, {cmd})
	}
	return
}

@(private)
_stats_present :: proc(ctx: ^Context) -> f64 {
	assert(ctx != nil, "_stats_present: nil context")
	when RENDER_STATS_ENABLED {
		started := platform_now()
		wg.SurfacePresent(ctx.surface)
		return platform_now() - started
	} else {
		wg.SurfacePresent(ctx.surface)
		return 0
	}
}

@(private)
_stats_stream_copy :: proc(ctx: ^Context, elapsed: f64) {
	when RENDER_STATS_ENABLED {
		assert(ctx != nil, "_stats_stream_copy: nil context")
		assert(elapsed >= 0, "_stats_stream_copy: negative time")
		ctx.stats_current.stream_copy_cpu_seconds += elapsed
	}
}

@(private)
_stats_stream_write :: proc(ctx: ^Context, uniform: bool, bytes: u64, elapsed: f64) {
	when RENDER_STATS_ENABLED {
		assert(ctx != nil, "_stats_stream_write: nil context")
		assert(bytes > 0, "_stats_stream_write: empty write")
		assert(elapsed >= 0, "_stats_stream_write: negative time")
		if uniform {
			ctx.stats_current.stream_uniform_write_calls += 1
			ctx.stats_current.stream_uniform_write_bytes += bytes
		} else {
			ctx.stats_current.stream_geometry_write_calls += 1
			ctx.stats_current.stream_geometry_write_bytes += bytes
		}
		ctx.stats_current.stream_write_cpu_seconds += elapsed
	}
}

@(private)
_stats_reservation_failure :: proc(ctx: ^Context, uniform: bool) {
	when RENDER_STATS_ENABLED {
		assert(ctx != nil, "_stats_reservation_failure: nil context")
		if uniform {
			ctx.stats_current.uniform_reservation_failures += 1
		} else {
			ctx.stats_current.geometry_reservation_failures += 1
		}
	}
}

@(private)
_stats_stream_slot_exhaustion :: proc(ctx: ^Context) {
	when RENDER_STATS_ENABLED {
		assert(ctx != nil, "_stats_stream_slot_exhaustion: nil context")
		ctx.stats_current.stream_slot_exhaustions += 1
	}
}

// _stats_gpu3d_pool_exhaustion counts GPU-3D fixed-pool exhaustion (mesh or
// pipeline slots) so hosts can see why 3D draws stopped appearing.
@(private)
_stats_gpu3d_pool_exhaustion :: proc(ctx: ^Context) {
	when RENDER_STATS_ENABLED {
		assert(ctx != nil, "_stats_gpu3d_pool_exhaustion: nil context")
		ctx.stats_current.gpu3d_pool_exhaustions += 1
	}
}

@(private)
_stats_gpu3d_mesh_upload :: proc(ctx: ^Context, vertices, indices: u32) {
	assert(ctx != nil, "_stats_gpu3d_mesh_upload: nil context")
	assert(vertices > 0, "_stats_gpu3d_mesh_upload: empty vertices")
	assert(indices > 0, "_stats_gpu3d_mesh_upload: empty indices")
	when RENDER_STATS_ENABLED {
		ctx.stats_current.gpu3d_mesh_uploads += 1
		ctx.stats_current.gpu3d_mesh_upload_bytes +=
			u64(vertices) * size_of(Gpu_3D_Vertex) + u64(indices) * size_of(u32)
		ctx.stats_current.gpu3d_vertices_resident += u64(vertices)
	}
}

@(private)
_stats_gpu3d_draw :: proc(ctx: ^Context, vertices, indices: u32) {
	assert(ctx != nil, "_stats_gpu3d_draw: nil context")
	assert(vertices > 0, "_stats_gpu3d_draw: empty vertices")
	assert(indices > 0, "_stats_gpu3d_draw: empty indices")
	when RENDER_STATS_ENABLED {
		ctx.stats_current.gpu3d_draws += 1
		ctx.stats_current.gpu3d_vertices_drawn += u64(vertices)
		ctx.stats_current.gpu3d_indices_drawn += u64(indices)
	}
}

// _stats_gpu3d_instanced_draw counts instanced draw chunks so hosts can
// verify batching (one chunk per GPU_3D_MAX_INSTANCES_PER_DRAW transforms).
@(private)
_stats_gpu3d_instanced_draw :: proc(ctx: ^Context) {
	assert(ctx != nil, "_stats_gpu3d_instanced_draw: nil context")
	when RENDER_STATS_ENABLED {
		ctx.stats_current.gpu3d_instanced_draws += 1
	}
}

@(private)
_stats_submission_tracking_failure :: proc(ctx: ^Context) {
	when RENDER_STATS_ENABLED {
		assert(ctx != nil, "_stats_submission_tracking_failure: nil context")
		ctx.stats_current.submission_tracking_failures += 1
	}
}

@(private)
_stats_stream_retirement_failure :: proc(ctx: ^Context) {
	when RENDER_STATS_ENABLED {
		assert(ctx != nil, "_stats_stream_retirement_failure: nil context")
		ctx.stats_current.stream_retirement_failures += 1
	}
}

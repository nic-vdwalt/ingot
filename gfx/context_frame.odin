// ingot:gfx - per-frame entry points: BeginDrawing/ClearBackground/EndDrawing
// and their context forms, render-pass management, batch flushing, and the
// active-pass routing used while a render target is bound.
package gfx

import wg "vendor:wgpu"

// --- per-frame -------------------------------------------------------------

BeginDrawing :: proc() {
	context_begin_drawing(default_context())
}

context_begin_drawing :: proc(ctx: ^Context) {
	assert(ctx != nil, "context_begin_drawing: nil context")
	_stats_frame_begin(ctx)
	pre_acquire_started := platform_now()
	_maybe_reconfigure(ctx)
	_frame_delivery_begin(ctx, ctx.stats_current.frame_index)
	platform_web_input_frame_begin(ctx)
	ctx.idle.surface_unavailable = ctx.fb_width <= 0 || ctx.fb_height <= 0
	pre_acquire_elapsed := platform_now() - pre_acquire_started
	_stats_frame_boundary_cpu(ctx, pre_acquire_elapsed, 0, 0, 0, 0, 0, 0, 0)
	if ctx.idle.surface_unavailable {
		_ = _submission_completed(&ctx.submissions)
		_frame_delivery_abandon(ctx, ctx.stats_current.frame_index)
		ctx.frame.has_frame = false
		return
	}

	stream_acquire_started := platform_now()
	if !renderer_frame_begin(ctx, &ctx.rend) {
		stream_acquire_elapsed := platform_now() - stream_acquire_started
		_stats_frame_boundary_cpu(ctx, 0, stream_acquire_elapsed, 0, 0, 0, 0, 0, 0)
		_frame_delivery_abandon(ctx, ctx.stats_current.frame_index)
		ctx.frame.has_frame = false
		return
	}
	stream_acquire_elapsed := platform_now() - stream_acquire_started
	_stats_frame_boundary_cpu(ctx, 0, stream_acquire_elapsed, 0, 0, 0, 0, 0, 0)
	acquire_started := platform_now()
	ctx.frame.surf_tex = wg.SurfaceGetCurrentTexture(ctx.surface)
	ctx.idle.surface_unavailable = ctx.frame.surf_tex.status == .Occluded
	acquire_elapsed := platform_now() - acquire_started
	_stats_context_cpu_times(ctx, 0, acquire_elapsed, 0, 0, 0)
	#partial switch ctx.frame.surf_tex.status {
	case .SuccessOptimal, .SuccessSuboptimal:
	// ok
	case .Outdated, .Lost:
		// The swapchain is stale (e.g. display change); reconfigure so the
		// next frame can acquire a fresh texture.
		_release_surface_texture(ctx)
		_stream_slot_abandon(&ctx.rend)
		if ctx.fb_width > 0 && ctx.fb_height > 0 {
			wg.SurfaceConfigure(ctx.surface, &ctx.config)
		}
		_frame_delivery_abandon(ctx, ctx.stats_current.frame_index)
		ctx.frame.has_frame = false
		return
	case:
		_release_surface_texture(ctx)
		_stream_slot_abandon(&ctx.rend)
		_frame_delivery_abandon(ctx, ctx.stats_current.frame_index)
		ctx.frame.has_frame = false
		return
	}
	post_acquire_started := platform_now()
	_assert_window_frame_contract(ctx)
	renderer_window_projection_refresh(&ctx.rend, ctx.queue, ctx.width, ctx.height)
	ctx.frame.view = wg.TextureCreateView(ctx.frame.surf_tex.texture, nil)
	ctx.frame.encoder = _gpu_timing_command_encoder(ctx, "window")
	ctx.frame.timing = {}
	ctx.frame.clear_color = Color{0, 0, 0, 255}
	ctx.frame.pass_begun = false
	ctx.frame.pass_name = "window"
	ctx.frame.pass_preserve = false
	ctx.frame.has_frame = true
	ctx.frame.scissor_on = false
	ctx.frame.scissor_empty = false
	post_acquire_elapsed := platform_now() - post_acquire_started
	_stats_frame_boundary_cpu(ctx, 0, 0, post_acquire_elapsed, 0, 0, 0, 0, 0)
	ctx.frame.draw_started = platform_now()
}

@(private)
_assert_window_frame_contract :: proc(ctx: ^Context) {
	assert(ctx != nil, "_assert_window_frame_contract: nil context")
	assert(ctx.width > 0 && ctx.height > 0, "_assert_window_frame_contract: invalid logical size")
	assert(
		ctx.fb_width > 0 && ctx.fb_height > 0,
		"_assert_window_frame_contract: invalid framebuffer",
	)
	assert(ctx.config.width == u32(ctx.fb_width), "_assert_window_frame_contract: width mismatch")
	assert(
		ctx.config.height == u32(ctx.fb_height),
		"_assert_window_frame_contract: height mismatch",
	)
	assert(ctx.frame.surf_tex.texture != nil, "_assert_window_frame_contract: nil texture")
}

ClearBackground :: proc(c: Color) {
	context_clear_background(default_context(), c)
}

context_clear_background :: proc(ctx: ^Context, c: Color) {
	assert(ctx != nil, "context_clear_background: nil context")
	// While a render target is bound but its pass hasn't begun yet, the clear
	// applies to the target (raylib: ClearBackground after BeginTextureMode
	// clears the target). Otherwise it sets the swapchain clear.
	if ctx.frame.rt != 0 && !ctx.frame.rt_pass_begun {
		ctx.frame.rt_clear = c
		ctx.frame.rt_should_clear = true
		return
	}
	ctx.frame.clear_color = c
}

// context_ensure_pass lazily begins the frame render pass so ClearBackground
// (called after BeginDrawing in raylib order) can set the loadOp clear value first.
@(private)
context_ensure_pass :: proc(ctx: ^Context) {
	assert(ctx != nil, "context_ensure_pass: nil context")
	if !ctx.frame.has_frame || ctx.frame.pass_begun do return
	cc := ctx.frame.clear_color
	name := ctx.frame.pass_name if len(ctx.frame.pass_name) > 0 else "window"
	load_op := wg.LoadOp.Load if ctx.frame.pass_preserve else wg.LoadOp.Clear
	writes := _gpu_timing_pass_writes(&ctx.gpu_timing, name)
	ctx.frame.pass = wg.CommandEncoderBeginRenderPass(
		ctx.frame.encoder,
		&{
			label = name,
			timestampWrites = writes.querySet != nil ? &writes : nil,
			colorAttachmentCount = 1,
			colorAttachments = &wg.RenderPassColorAttachment {
				view = ctx.frame.view,
				depthSlice = wg.DEPTH_SLICE_UNDEFINED,
				loadOp = load_op,
				storeOp = .Store,
				clearValue = {
					f64(cc.r) / 255.0,
					f64(cc.g) / 255.0,
					f64(cc.b) / 255.0,
					f64(cc.a) / 255.0,
				},
			},
		},
	)
	when GPU_TIMING_DIAGNOSTICS {
		if writes.querySet != nil {
			_gpu_timing_diagnostic_bind(
				&ctx.gpu_timing.diagnostics[0],
				u32(ctx.gpu_timing.active_slot),
				writes.beginningOfPassWriteIndex / 2,
				ctx.frame.encoder,
				ctx.frame.pass,
				load_op,
				.Store,
			)
			_gpu_timing_diagnostic_attachment(ctx, writes.beginningOfPassWriteIndex, 0, 0)
		}
	}
	_stats_render_pass(ctx)
	ctx.frame.pass_begun = true
	// A new pass starts with a full-attachment scissor; restore any active clip.
	if ctx.frame.scissor_on && !ctx.frame.scissor_empty {
		assert(ctx.frame.sc_w > 0)
		assert(ctx.frame.sc_h > 0)
		wg.RenderPassEncoderSetScissorRect(
			ctx.frame.pass,
			ctx.frame.sc_x,
			ctx.frame.sc_y,
			ctx.frame.sc_w,
			ctx.frame.sc_h,
		)
	}
}

context_split_frame_pass :: proc(ctx: ^Context, name: string) -> bool {
	assert(ctx != nil, "context_split_frame_pass: nil context")
	assert(len(name) > 0, "context_split_frame_pass: empty name")
	if !ctx.frame.has_frame || ctx.frame.rt != 0 do return false
	if ctx.resources.gpu_3d.active_pass_generation != 0 do return false
	if ctx.frame.pass_begun {
		if !ctx.frame.scissor_empty {
			renderer_flush(ctx, &ctx.rend, ctx.frame.pass, .Manual)
		} else {
			clear(&ctx.rend.verts)
			clear(&ctx.rend.indices)
		}
		wg.RenderPassEncoderEnd(ctx.frame.pass)
		wg.RenderPassEncoderRelease(ctx.frame.pass)
		ctx.frame.pass = nil
		ctx.frame.pass_begun = false
		ctx.frame.pass_preserve = true
	}
	ctx.frame.pass_name = name
	assert(!ctx.frame.pass_begun)
	return true
}

split_frame_pass :: proc(name: string) -> bool {
	return context_split_frame_pass(default_context(), name)
}

EndDrawing :: proc() {
	context_end_drawing(default_context())
}

context_end_drawing :: proc(ctx: ^Context) {
	assert(ctx != nil, "context_end_drawing: nil context")
	if ctx.frame.has_frame {
		assert(ctx.frame.draw_started > 0, "context_end_drawing: missing draw start")
		_stats_draw_cpu(ctx, platform_now() - ctx.frame.draw_started)
		flush_started := platform_now()
		context_ensure_pass(ctx) // guarantee a clear even on empty frames
		if !ctx.frame.scissor_empty {
			renderer_flush(ctx, &ctx.rend, ctx.frame.pass, .Frame_End)
		} else {
			clear(&ctx.rend.verts)
			clear(&ctx.rend.indices)
		}
		wg.RenderPassEncoderEnd(ctx.frame.pass)
		wg.RenderPassEncoderRelease(ctx.frame.pass)
		flush_elapsed := platform_now() - flush_started
		_stats_frame_boundary_cpu(ctx, 0, 0, 0, flush_elapsed, 0, 0, 0, 0)

		retirement := _submission_reserve(&ctx.submissions)
		upload_started := platform_now()
		if retirement != 0 {
			slot_uploaded := _stream_slot_upload(ctx, &ctx.rend)
			assert(slot_uploaded, "frame end: stream upload failed")
		}
		upload_elapsed := platform_now() - upload_started
		_stats_frame_boundary_cpu(ctx, 0, 0, 0, 0, upload_elapsed, 0, 0, 0)
		_gpu_timing_encoder_end(ctx, ctx.frame.encoder, ctx.frame.timing)
		_gpu_timing_frame_close(ctx, ctx.frame.encoder)
		cmd, encode_elapsed, submit_elapsed := _stats_finish_submit(
			ctx,
			ctx.frame.encoder,
			retirement != 0,
		)
		_stats_submission_call(
			ctx,
			.Final,
			upload_elapsed,
			encode_elapsed,
			submit_elapsed,
			retirement != 0,
			cmd != nil,
			retirement != 0 && cmd != nil,
		)
		if retirement != 0 && cmd != nil {
			_gpu_timing_frame_submitted(ctx)
			_stats_queue_submission(ctx)
			committed := _submission_commit(
				&ctx.submissions,
				retirement,
				ctx.stats_current.frame_index,
			)
			assert(committed, "frame end: submission commit failed")
			if !_stream_slot_submitted(&ctx.rend, retirement) {
				_stats_stream_retirement_failure(ctx)
			}
		} else {
			_gpu_timing_frame_abandon(ctx)
			if retirement != 0 {
				rolled_back := _submission_rollback(&ctx.submissions, retirement)
				assert(rolled_back, "frame end: submission rollback failed")
			}
			_stream_slot_abandon(&ctx.rend)
			_stats_stream_retirement_failure(ctx)
		}
		if cmd != nil do wg.CommandBufferRelease(cmd)
		wg.CommandEncoderRelease(ctx.frame.encoder)
		present_elapsed := _stats_present(ctx)
		_stats_context_cpu_times(ctx, 0, 0, encode_elapsed, submit_elapsed, present_elapsed)
		cleanup_started := platform_now()
		wg.TextureViewRelease(ctx.frame.view)
		_release_surface_texture(ctx)
		ctx.presented_frames += 1
		ctx.frame.has_frame = false
		_flush_retired(ctx)
		_renderer_report_overflow(&ctx.rend)
		cleanup_elapsed := platform_now() - cleanup_started
		_stats_frame_boundary_cpu(ctx, 0, 0, 0, 0, 0, cleanup_elapsed, 0, 0)
	} else {
		_gpu_timing_frame_abandon(ctx)
		clear(&ctx.rend.verts)
		clear(&ctx.rend.indices)
	}

	platform_web_input_frame_end(ctx)
	input_started := platform_now()
	when ODIN_OS != .JS {
		input_poll(ctx)
	}
	input_elapsed := platform_now() - input_started
	_stats_frame_boundary_cpu(ctx, 0, 0, 0, 0, 0, 0, input_elapsed, 0)
	frame_timing_started := platform_now()
	_frame_timing(ctx, platform_should_close(ctx))
	frame_timing_elapsed := platform_now() - frame_timing_started
	_stats_frame_boundary_cpu(ctx, 0, 0, 0, 0, 0, 0, 0, frame_timing_elapsed)
	_stats_frame_end(ctx)
	_frame_delivery_cpu(ctx, ctx.stats_latest)
}

// _release_surface_texture drops the owned reference returned by
// SurfaceGetCurrentTexture. Failing to do this leaks one texture per frame
// until the process runs out of address space.
@(private)
_release_surface_texture :: proc(ctx: ^Context) {
	assert(ctx != nil, "_release_surface_texture: nil context")
	if ctx.frame.surf_tex.texture != nil {
		wg.TextureRelease(ctx.frame.surf_tex.texture)
		ctx.frame.surf_tex.texture = nil
	}
}

// flush_batch forces pending 2D geometry to record into the current render pass
// (raylib rlDrawRenderBatchActive parity - used to order custom draws).
context_flush_batch :: proc(ctx: ^Context) {
	assert(ctx != nil, "context_flush_batch: nil context")
	if ctx.frame.has_frame && context_active_pass_begun(ctx) && !ctx.frame.scissor_empty {
		renderer_flush(ctx, &ctx.rend, context_active_pass(ctx))
	}
}

flush_batch :: proc() {
	context_flush_batch(default_context())
}

// --- active pass routing (render targets) ----------------------------------
// When a render target is bound (BeginTextureMode) the batch records into the
// target's pass on its own command encoder; otherwise the swapchain pass.

// context_active_pass returns the render pass the batch renderer should record into.
@(private)
context_active_pass :: proc(ctx: ^Context) -> wg.RenderPassEncoder {
	assert(ctx != nil, "context_active_pass: nil context")
	if ctx.frame.rt != 0 do return ctx.frame.rt_pass
	return ctx.frame.pass
}

// _cur_target_format returns the wgpu colour format of the pass draws currently
// target (the swapchain, or the bound render target). Custom-shader pipelines
// are format-specific, so they are built lazily per target format.
@(private)
_cur_target_format :: proc(ctx: ^Context) -> wg.TextureFormat {
	assert(ctx != nil, "_cur_target_format: nil context")
	if ctx.frame.rt != 0 {
		e := context_get_texture(ctx, ctx.frame.rt)
		if e != nil && e.wgformat != .Undefined do return e.wgformat
	}
	return ctx.format
}

// context_active_pass_begun reports whether the active pass has begun.
@(private)
context_active_pass_begun :: proc(ctx: ^Context) -> bool {
	assert(ctx != nil, "context_active_pass_begun: nil context")
	if !ctx.frame.has_frame do return false
	if ctx.frame.rt != 0 do return ctx.frame.rt_pass_begun
	return ctx.frame.pass_begun
}

// context_attachment_px returns the real pixel dimensions of the current 2D
// pass target: the bound render target, else the configured swapchain surface.
// ctx.config is authoritative for the swapchain texture size (kept in lockstep
// with SurfaceConfigure), so scissor rects computed from it can never exceed
// the attachment even if ctx.fb_width lags an async web resize for a frame.
@(private)
context_attachment_px :: proc(ctx: ^Context) -> (f32, f32) {
	assert(ctx != nil, "context_attachment_px: nil context")
	if ctx.frame.rt != 0 do return f32(ctx.frame.rt_w), f32(ctx.frame.rt_h)
	return f32(max(ctx.config.width, 1)), f32(max(ctx.config.height, 1))
}

// context_ensure_active_pass lazily begins whichever pass is current: the
// render target's pass while one is bound, otherwise the swapchain pass.
@(private)
context_ensure_active_pass :: proc(ctx: ^Context) {
	assert(ctx != nil, "context_ensure_active_pass: nil context")
	if ctx.frame.rt != 0 {
		context_ensure_rt_pass(ctx)
	} else {
		context_ensure_pass(ctx)
	}
}

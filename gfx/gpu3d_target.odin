package gfx

import wg "vendor:wgpu"

@(private)
_gpu_3d_sample_count :: proc(antialiasing: Gpu_3D_Antialiasing) -> u32 {
	#partial switch antialiasing {
	case .None:
		return 1
	case .MSAA_4X:
		return 4
	}
	return 1
}

@(private)
_gpu_3d_target_create :: proc(
	ctx: ^Context,
	width, height: i32,
	antialiasing: Gpu_3D_Antialiasing,
) -> (
	Gpu_3D_Target,
	bool,
) {
	assert(ctx != nil, "_gpu_3d_target_create: nil context")
	if !ctx.initialized || width <= 0 || height <= 0 do return {}, false
	target := Gpu_3D_Target {
		texture      = context_load_render_texture_ex(ctx, width, height, ctx.format, true),
		antialiasing = antialiasing,
	}
	ok := target.texture.texture.id != 0 && target.texture.depth.id != 0
	if !ok {
		if target.texture.texture.id != 0 do context_unload_render_texture(ctx, target.texture)
		return {}, false
	}
	if antialiasing == .MSAA_4X {
		target.multisample_color = _new_rt_attachment(ctx, width, height, ctx.format, 4)
		target.multisample_depth = _new_rt_attachment(ctx, width, height, .Depth24Plus, 4)
		if target.multisample_color == nil || target.multisample_depth == nil {
			_gpu_3d_target_destroy(ctx, &target)
			return {}, false
		}
	}
	return target, true
}

@(private)
_gpu_3d_target_destroy :: proc(ctx: ^Context, target: ^Gpu_3D_Target) {
	assert(ctx != nil, "_gpu_3d_target_destroy: nil context")
	assert(target != nil, "_gpu_3d_target_destroy: nil target")
	assert(
		ctx.resources.gpu_3d.active_pass_generation == 0,
		"_gpu_3d_target_destroy: active GPU 3D pass",
	)
	_destroy_rt_attachment(ctx, target.multisample_color)
	_destroy_rt_attachment(ctx, target.multisample_depth)
	if target.texture.texture.id != 0 do context_unload_render_texture(ctx, target.texture)
	target^ = {}
	assert(target.texture.texture.id == 0)
	assert(target.multisample_color == nil && target.multisample_depth == nil)
}

@(private)
_gpu_3d_target_views :: proc(
	ctx: ^Context,
	target: ^Gpu_3D_Target,
) -> (
	wg.TextureView,
	wg.TextureView,
	wg.TextureView,
	u32,
	bool,
) {
	assert(ctx != nil && target != nil, "_gpu_3d_target_views: invalid arguments")
	color_slot := _texture_slot_context(ctx.id, &ctx.resources.textures, target.texture.texture.id)
	depth_slot := _texture_slot_context(ctx.id, &ctx.resources.textures, target.texture.depth.id)
	if color_slot == nil || depth_slot == nil do return nil, nil, nil, 0, false
	if color_slot.entry == nil || depth_slot.entry == nil do return nil, nil, nil, 0, false
	if color_slot.entry.view == nil || depth_slot.entry.view == nil do return nil, nil, nil, 0, false
	assert(color_slot.entry.sample_count == 1, "_gpu_3d_target_views: multisampled resolve color")
	assert(depth_slot.entry.sample_count == 1, "_gpu_3d_target_views: multisampled resolve depth")
	sample_count := _gpu_3d_sample_count(target.antialiasing)
	if sample_count == 1 do return color_slot.entry.view, depth_slot.entry.view, nil, 1, true
	assert(target.multisample_color != nil, "_gpu_3d_target_views: missing multisample color")
	assert(target.multisample_depth != nil, "_gpu_3d_target_views: missing multisample depth")
	color := target.multisample_color
	depth := target.multisample_depth
	assert(
		color.view != nil && depth.view != nil,
		"_gpu_3d_target_views: invalid multisample view",
	)
	assert(color.sample_count == sample_count, "_gpu_3d_target_views: color sample-count mismatch")
	assert(depth.sample_count == sample_count, "_gpu_3d_target_views: depth sample-count mismatch")
	assert(
		color.wgformat == color_slot.entry.wgformat,
		"_gpu_3d_target_views: resolve format mismatch",
	)
	assert(
		color.width == color_slot.entry.width && color.height == color_slot.entry.height,
		"_gpu_3d_target_views: resolve dimensions mismatch",
	)
	assert(
		depth.width == depth_slot.entry.width && depth.height == depth_slot.entry.height,
		"_gpu_3d_target_views: depth dimensions mismatch",
	)
	return color.view, depth.view, color_slot.entry.view, sample_count, true
}

context_create_gpu_3d_target :: proc(
	ctx: ^Context,
	width, height: i32,
	antialiasing: Gpu_3D_Antialiasing = .None,
) -> (
	Gpu_3D_Target,
	bool,
) {
	assert(ctx != nil, "context_create_gpu_3d_target: nil context")
	return _gpu_3d_target_create(ctx, width, height, antialiasing)
}

create_gpu_3d_target :: proc(
	width, height: i32,
	antialiasing: Gpu_3D_Antialiasing = .None,
) -> (
	Gpu_3D_Target,
	bool,
) {
	return context_create_gpu_3d_target(default_context(), width, height, antialiasing)
}

context_destroy_gpu_3d_target :: proc(ctx: ^Context, target: ^Gpu_3D_Target) {
	assert(ctx != nil, "context_destroy_gpu_3d_target: nil context")
	_gpu_3d_target_destroy(ctx, target)
}

destroy_gpu_3d_target :: proc(target: ^Gpu_3D_Target) {
	context_destroy_gpu_3d_target(default_context(), target)
}

gpu_3d_target_size :: proc(target: ^Gpu_3D_Target) -> (width, height: i32, ok: bool) {
	if target == nil do return 0, 0, false
	color := target.texture.texture
	depth := target.texture.depth
	if color.id == 0 || depth.id == 0 do return 0, 0, false
	if color.width <= 0 || color.height <= 0 do return 0, 0, false
	if color.width != depth.width || color.height != depth.height do return 0, 0, false
	return color.width, color.height, true
}

gpu_3d_target_color_texture :: proc(target: ^Gpu_3D_Target) -> Texture2D {
	if target == nil do return {}
	return target.texture.texture
}

gpu_3d_target_depth_texture :: proc(target: ^Gpu_3D_Target) -> (Texture2D, bool) {
	if target == nil || target.antialiasing != .None do return {}, false
	if _, _, ok := gpu_3d_target_size(target); !ok do return {}, false
	return target.texture.depth, true
}

@(private)
_gpu_3d_target_copy_compatible :: proc(source, destination: ^Gpu_3D_Target) -> bool {
	if source == nil || destination == nil || source == destination do return false
	if source.antialiasing != .None || destination.antialiasing != .None do return false
	width, height, source_ok := gpu_3d_target_size(source)
	destination_width, destination_height, destination_ok := gpu_3d_target_size(destination)
	if !source_ok ||
	   !destination_ok ||
	   width != destination_width ||
	   height != destination_height {
		return false
	}
	return(
		source.texture.texture.id != destination.texture.texture.id &&
		source.texture.depth.id != destination.texture.depth.id \
	)
}

@(private)
_Gpu_3D_Target_Copy :: struct {
	source_color:      ^Tex_Entry,
	source_depth:      ^Tex_Entry,
	destination_color: ^Tex_Entry,
	destination_depth: ^Tex_Entry,
	extent:            wg.Extent3D,
}

@(private)
_gpu_3d_target_copy_prepare :: proc(
	ctx: ^Context,
	source, destination: ^Gpu_3D_Target,
) -> (
	_Gpu_3D_Target_Copy,
	bool,
) {
	if ctx == nil || !_gpu_3d_target_copy_compatible(source, destination) do return {}, false
	source_color := context_get_texture(ctx, source.texture.texture.id)
	source_depth := context_get_texture(ctx, source.texture.depth.id)
	destination_color := context_get_texture(ctx, destination.texture.texture.id)
	destination_depth := context_get_texture(ctx, destination.texture.depth.id)
	if source_color == nil ||
	   source_depth == nil ||
	   destination_color == nil ||
	   destination_depth == nil {
		return {}, false
	}
	if source_color.wgformat != destination_color.wgformat ||
	   source_depth.wgformat != destination_depth.wgformat {
		return {}, false
	}
	width, height, _ := gpu_3d_target_size(source)
	return {
			source_color = source_color,
			source_depth = source_depth,
			destination_color = destination_color,
			destination_depth = destination_depth,
			extent = {u32(width), u32(height), 1},
		},
		true
}

@(private)
_gpu_3d_target_copy_encode :: proc(encoder: wg.CommandEncoder, copy: _Gpu_3D_Target_Copy) {
	assert(encoder != nil)
	assert(copy.source_color != nil && copy.source_depth != nil)
	assert(copy.destination_color != nil && copy.destination_depth != nil)
	color_source := wg.TexelCopyTextureInfo {
		texture = copy.source_color.tex,
		aspect  = .All,
	}
	color_destination := wg.TexelCopyTextureInfo {
		texture = copy.destination_color.tex,
		aspect  = .All,
	}
	depth_source := wg.TexelCopyTextureInfo {
		texture = copy.source_depth.tex,
		aspect  = .DepthOnly,
	}
	depth_destination := wg.TexelCopyTextureInfo {
		texture = copy.destination_depth.tex,
		aspect  = .DepthOnly,
	}
	extent := copy.extent
	wg.CommandEncoderCopyTextureToTexture(encoder, &color_source, &color_destination, &extent)
	wg.CommandEncoderCopyTextureToTexture(encoder, &depth_source, &depth_destination, &extent)
}

context_copy_gpu_3d_target_named :: proc(
	ctx: ^Context,
	source, destination: ^Gpu_3D_Target,
	name: string,
) -> bool {
	assert(ctx != nil, "context_copy_gpu_3d_target_named: nil context")
	if ctx.resources.gpu_3d.active_pass_generation != 0 do return false
	copy, ok := _gpu_3d_target_copy_prepare(ctx, source, destination)
	if !ok do return false
	encoder := _gpu_timing_command_encoder(ctx, name)
	if encoder == nil do return false
	timing := _gpu_timing_encoder_begin(ctx, encoder, name)
	_gpu_3d_target_copy_encode(encoder, copy)
	_gpu_timing_encoder_end(ctx, encoder, timing)
	finish_started := platform_now()
	command := wg.CommandEncoderFinish(encoder, nil)
	finish_elapsed := platform_now() - finish_started
	if command == nil {
		when GPU_TIMING_DIAGNOSTICS {
			_gpu_timing_diagnostic_encoder_retire(&ctx.gpu_timing.diagnostics[0], encoder)
		}
		wg.CommandEncoderRelease(encoder)
		return false
	}
	when GPU_TIMING_DIAGNOSTICS {
		_gpu_timing_diagnostic_submit(&ctx.gpu_timing.diagnostics[0], encoder)
	}
	submit_started := platform_now()
	wg.QueueSubmit(ctx.queue, {command})
	submit_elapsed := platform_now() - submit_started
	_stats_gpu_3d_target_copy_submission(ctx, finish_elapsed, submit_elapsed)
	wg.CommandBufferRelease(command)
	wg.CommandEncoderRelease(encoder)
	return true
}

@(private)
_stats_gpu_3d_target_copy_submission :: proc(ctx: ^Context, finish, submit: f64) {
	_stats_submission_call(ctx, .Intermediate, 0, finish, submit, false, true, true)
	_stats_context_cpu_times(ctx, 0, 0, finish, submit, 0)
	_stats_queue_submission(ctx)
}

context_copy_gpu_3d_target :: proc(ctx: ^Context, source, destination: ^Gpu_3D_Target) -> bool {
	return context_copy_gpu_3d_target_named(ctx, source, destination, "gpu3d-copy")
}

copy_gpu_3d_target_named :: proc(source, destination: ^Gpu_3D_Target, name: string) -> bool {
	return context_copy_gpu_3d_target_named(default_context(), source, destination, name)
}

copy_gpu_3d_target :: proc(source, destination: ^Gpu_3D_Target) -> bool {
	return context_copy_gpu_3d_target(default_context(), source, destination)
}

context_resize_gpu_3d_target :: proc(
	ctx: ^Context,
	target: ^Gpu_3D_Target,
	width, height: i32,
) -> bool {
	assert(ctx != nil, "context_resize_gpu_3d_target: nil context")
	assert(target != nil, "context_resize_gpu_3d_target: nil target")
	assert(
		ctx.resources.gpu_3d.active_pass_generation == 0,
		"context_resize_gpu_3d_target: active GPU 3D pass",
	)
	if width <= 0 || height <= 0 do return false
	if target.texture.texture.width == width && target.texture.texture.height == height do return true
	antialiasing := target.antialiasing
	replacement, ok := _gpu_3d_target_create(ctx, width, height, antialiasing)
	if !ok do return false
	_gpu_3d_target_destroy(ctx, target)
	target^ = replacement
	assert(target.texture.texture.width == width, "resize_gpu_3d_target: wrong width")
	assert(target.texture.texture.height == height, "resize_gpu_3d_target: wrong height")
	assert(target.antialiasing == antialiasing, "context_resize_gpu_3d_target: wrong antialiasing")
	return true
}

resize_gpu_3d_target :: proc(target: ^Gpu_3D_Target, width, height: i32) -> bool {
	return context_resize_gpu_3d_target(default_context(), target, width, height)
}

context_resize_gpu_3d_target_to_render_size :: proc(
	ctx: ^Context,
	target: ^Gpu_3D_Target,
) -> Gpu_3D_Target_Resize_Result {
	assert(ctx != nil, "context_resize_gpu_3d_target_to_render_size: nil context")
	assert(target != nil, "context_resize_gpu_3d_target_to_render_size: nil target")
	width := context_render_width(ctx)
	height := context_render_height(ctx)
	if width <= 0 || height <= 0 do return .Deferred
	current_width, current_height, ok := gpu_3d_target_size(target)
	if !ok do return .Failed
	if current_width == width && current_height == height do return .Unchanged
	if !context_resize_gpu_3d_target(ctx, target, width, height) do return .Failed
	return .Resized
}

resize_gpu_3d_target_to_render_size :: proc(
	target: ^Gpu_3D_Target,
) -> Gpu_3D_Target_Resize_Result {
	return context_resize_gpu_3d_target_to_render_size(default_context(), target)
}

@(private)
_gpu_3d_target_source_rectangle :: proc(target: ^Gpu_3D_Target) -> (Rectangle, bool) {
	assert(target != nil, "_gpu_3d_target_source_rectangle: nil target")
	width, height, ok := gpu_3d_target_size(target)
	if !ok do return {}, false
	return {0, 0, f32(width), f32(height)}, true
}

context_draw_gpu_3d_target :: proc(
	ctx: ^Context,
	target: ^Gpu_3D_Target,
	destination: Rectangle,
	tint: Color = WHITE,
) {
	assert(ctx != nil, "context_draw_gpu_3d_target: nil context")
	assert(target != nil, "context_draw_gpu_3d_target: nil target")
	assert(
		ctx.resources.gpu_3d.active_pass_generation == 0,
		"context_draw_gpu_3d_target: active GPU 3D pass",
	)
	if context_get_texture(ctx, target.texture.texture.id) == nil do return
	source, ok := _gpu_3d_target_source_rectangle(target)
	if !ok do return
	context_draw_texture_pro(ctx, target.texture.texture, source, destination, {}, 0, tint)
}

draw_gpu_3d_target :: proc(target: ^Gpu_3D_Target, destination: Rectangle, tint: Color = WHITE) {
	context_draw_gpu_3d_target(default_context(), target, destination, tint)
}

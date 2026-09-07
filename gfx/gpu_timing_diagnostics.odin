package gfx

import wg "vendor:wgpu"

GPU_TIMING_DIAGNOSTICS :: #config(INGOT_GPU_TIMING_DIAGNOSTICS, false)
GPU_TIMING_DIAGNOSTIC_CAPACITY :: 64
GPU_TIMING_DIAGNOSTIC_DRAWS_PER_PASS :: 4
GPU_TIMING_DIAGNOSTIC_GEOMETRY_CAPACITY :: 16
GPU_TIMING_DIAGNOSTIC_VERTICES_MAX :: 2048
GPU_TIMING_DIAGNOSTIC_INDICES_MAX :: 4096

#assert(!GPU_TIMING_DIAGNOSTICS || RENDER_STATS_ENABLED)

_gpu_timing_diagnostic_render_pass :: proc(
	ctx: ^Context,
	writes: wg.PassTimestampWrites,
	encoder: wg.CommandEncoder,
	pass: wg.RenderPassEncoder,
	color: wg.RenderPassColorAttachment,
	target: ^Gpu_3D_Target,
	depth: wg.RenderPassDepthStencilAttachment = {},
) {
	assert(ctx != nil)
	when GPU_TIMING_DIAGNOSTICS {
		if writes.querySet == nil do return
		assert(ctx.gpu_timing.active_slot >= 0)
		assert(ctx.gpu_timing.active_slot < GPU_TIMING_FRAME_SLOTS)
		assert(writes.beginningOfPassWriteIndex < GPU_TIMING_QUERY_COUNT)
		assert(writes.beginningOfPassWriteIndex % 2 == 0)
		_gpu_timing_diagnostic_bind(
			&ctx.gpu_timing.diagnostics[0],
			u32(ctx.gpu_timing.active_slot),
			writes.beginningOfPassWriteIndex / 2,
			encoder,
			pass,
			color.loadOp,
			color.storeOp,
		)
		assert(target != nil)
		_gpu_timing_diagnostic_attachment(
			ctx,
			writes.beginningOfPassWriteIndex,
			target.texture.texture.id,
			target.texture.depth.id,
		)
		bindings := &ctx.gpu_timing.diagnostics[0].bindings[ctx.gpu_timing.active_slot]
		record := &bindings[writes.beginningOfPassWriteIndex / 2].record
		record.sample_count = _gpu_3d_sample_count(target.antialiasing)
		record.depth_load = depth.depthLoadOp
		record.depth_store = depth.depthStoreOp
		record.depth_clear = depth.depthClearValue
		record.depth_clear_bits = transmute(u32)depth.depthClearValue
		record.depth_read_only = depth.depthReadOnly
		record.color_clear = color.clearValue
		record.color_clear_bits = transmute([4]u64)color.clearValue
		record.clear_bits_known = true
	}
}

Gpu_Timing_Diagnostic :: struct {
	epoch:              u64,
	frame:              u64,
	generation:         u64,
	map_request:        u64,
	encoder_id:         u64,
	submit_ordinal:     u64,
	resolve_ordinal:    u64,
	resolve_encoder_id: u64,
	begin_tick:         u64,
	end_tick:           u64,
	previous:           Gpu_Timing_Diagnostic_Previous,
	draw_count:         u32,
	draws:              [GPU_TIMING_DIAGNOSTIC_DRAWS_PER_PASS]Gpu_Timing_Diagnostic_Draw,
	draws_dropped:      u32,
	query_begin:        u32,
	slot_index:         u32,
	// Submission topology: how many timed spans the slot carried when it was
	// submitted and how many of them were recorded in this pass's encoder, so
	// a replay can reject frames whose command order it cannot reproduce.
	span_count:         u32,
	encoder_spans:      u32,
	load:               wg.LoadOp,
	store:              wg.StoreOp,
	label:              Gpu_Timing_Label,
	width:              u32,
	height:             u32,
	format:             wg.TextureFormat,
	depth_format:       wg.TextureFormat,
	depth_load:         wg.LoadOp,
	depth_store:        wg.StoreOp,
	depth_clear:        f32,
	depth_read_only:    wg.Bool,
	color_clear:        wg.Color,
	color_clear_bits:   [4]u64,
	depth_clear_bits:   u32,
	clear_bits_known:   bool,
	sample_count:       u32,
	callback_status:    wg.MapAsyncStatus,
	collection_id:      u64,
}

Gpu_Timing_Diagnostic_Draw_Path :: enum u32 {
	Unknown,
	Batch_Builtin,
	Gpu_3D,
}

Gpu_Timing_Diagnostic_Geometry :: struct {
	vertex_count: u32,
	index_count:  u32,
	vertices:     [GPU_TIMING_DIAGNOSTIC_VERTICES_MAX]Vertex,
	indices:      [GPU_TIMING_DIAGNOSTIC_INDICES_MAX]u32,
}

Gpu_Timing_Diagnostic_Draw :: struct {
	neutral_texture:    bool,
	atlas_id:           u32,
	atlas_upload_count: u32,
	atlas_filter:       u32,
	atlas_known:        bool,
	geometry_id:        u32,
	projection:         [4]f32,
	projection_bits:    [4]u32,
	projection_known:   bool,
	path:               Gpu_Timing_Diagnostic_Draw_Path,
	known:              bool,
	indexed:            bool,
	count:              u32,
	instances:          u32,
	shader_id:          u32,
	pipeline_kind:      u32,
	pipeline_style:     u32,
	scissor:            [4]u32,
}

Gpu_Timing_Diagnostic_Previous :: struct {
	valid:      bool,
	epoch:      u64,
	frame:      u64,
	generation: u64,
	begin_tick: u64,
	end_tick:   u64,
}

Gpu_Timing_Diagnostic_Binding :: struct {
	encoder: wg.CommandEncoder,
	pass:    wg.RenderPassEncoder,
	record:  Gpu_Timing_Diagnostic,
}

Gpu_Timing_Diagnostic_Encoder :: struct {
	handle: wg.CommandEncoder,
	id:     u64,
}

Gpu_Timing_Diagnostic_Category :: struct {
	label:     Gpu_Timing_Label,
	zero_end:  bool,
	has_draws: bool,
	count:     u64,
	first:     Gpu_Timing_Diagnostic,
}

Gpu_Timing_Diagnostic_Snapshot :: struct {
	geometry_count:    u32,
	geometry_dropped:  u64,
	failures:          [GPU_TIMING_DIAGNOSTIC_CAPACITY]Gpu_Timing_Diagnostic,
	failure_count:     u32,
	dropped:           u64,
	encoder_overflow:  u64,
	missing_encoder:   u64,
	categories:        [GPU_TIMING_DIAGNOSTIC_CAPACITY]Gpu_Timing_Diagnostic_Category,
	category_count:    u32,
	category_overflow: u64,
}

Gpu_Timing_Diagnostics :: struct {
	atlas:             Gpu_Timing_Atlas_Evidence,
	geometry:          [GPU_TIMING_DIAGNOSTIC_GEOMETRY_CAPACITY]Gpu_Timing_Diagnostic_Geometry,
	geometry_count:    u32,
	geometry_dropped:  u64,
	bindings:          [GPU_TIMING_FRAME_SLOTS][GPU_TIMING_MAX_SPANS]Gpu_Timing_Diagnostic_Binding,
	failures:          [GPU_TIMING_DIAGNOSTIC_CAPACITY]Gpu_Timing_Diagnostic,
	encoders:          [GPU_TIMING_MAX_SPANS]Gpu_Timing_Diagnostic_Encoder,
	categories:        [GPU_TIMING_DIAGNOSTIC_CAPACITY]Gpu_Timing_Diagnostic_Category,
	category_count:    u32,
	category_overflow: u64,
	encoder_next:      u64,
	collection_next:   u64,
	submit_ordinal:    u64,
	failure_count:     u32,
	dropped:           u64,
	encoder_overflow:  u64,
	missing_encoder:   u64,
	previous:          [GPU_TIMING_FRAME_SLOTS][GPU_TIMING_MAX_SPANS]Gpu_Timing_Diagnostic_Previous,
	resolve_encoder:   [GPU_TIMING_FRAME_SLOTS]wg.CommandEncoder,
	resolve_ordinal:   [GPU_TIMING_FRAME_SLOTS]u64,
}

context_gpu_timing_diagnostics :: proc(ctx: ^Context) -> Gpu_Timing_Diagnostic_Snapshot {
	assert(ctx != nil)
	when GPU_TIMING_DIAGNOSTICS {
		state := &ctx.gpu_timing.diagnostics[0]
		assert(state.failure_count <= GPU_TIMING_DIAGNOSTIC_CAPACITY)
		return {
			geometry_count = state.geometry_count,
			geometry_dropped = state.geometry_dropped,
			failures = state.failures,
			failure_count = state.failure_count,
			dropped = state.dropped,
			encoder_overflow = state.encoder_overflow,
			missing_encoder = state.missing_encoder,
			categories = state.categories,
			category_count = state.category_count,
			category_overflow = state.category_overflow,
		}
	} else {
		return {}
	}
}

_gpu_timing_diagnostic_attachment :: proc(
	ctx: ^Context,
	query_begin: u32,
	color_id, depth_id: u32,
) {
	assert(ctx != nil)
	when GPU_TIMING_DIAGNOSTICS {
		if ctx.gpu_timing.active_slot < 0 do return
		assert(query_begin < GPU_TIMING_QUERY_COUNT)
		bindings := &ctx.gpu_timing.diagnostics[0].bindings[ctx.gpu_timing.active_slot]
		record := &bindings[query_begin / 2].record
		if color_id == 0 {
			record.width = ctx.config.width
			record.height = ctx.config.height
			record.format = ctx.config.format
			record.sample_count = 1
			clear := ctx.frame.clear_color
			record.color_clear = {
				f64(clear.r) / 255.0,
				f64(clear.g) / 255.0,
				f64(clear.b) / 255.0,
				f64(clear.a) / 255.0,
			}
			record.color_clear_bits = transmute([4]u64)record.color_clear
			record.clear_bits_known = true
		} else if color := context_get_texture(ctx, color_id); color != nil {
			record.width = u32(color.width)
			record.height = u32(color.height)
			record.format = color.wgformat
			record.sample_count = color.sample_count
		}
		if depth := context_get_texture(ctx, depth_id); depth != nil {
			record.depth_format = depth.wgformat
		}
	}
}

_gpu_timing_diagnostic_encoder_created :: proc(
	state: ^Gpu_Timing_Diagnostics,
	encoder: wg.CommandEncoder,
) {
	assert(state != nil)
	when GPU_TIMING_DIAGNOSTICS {
		if encoder == nil do return
		for &entry in state.encoders {
			if entry.handle != nil do continue
			state.encoder_next += 1
			ensure(state.encoder_next != 0)
			entry = {encoder, state.encoder_next}
			return
		}
		state.encoder_overflow += 1
	}
}

_gpu_timing_diagnostic_encoder_retire :: proc(
	state: ^Gpu_Timing_Diagnostics,
	encoder: wg.CommandEncoder,
) {
	assert(state != nil)
	when GPU_TIMING_DIAGNOSTICS {
		if encoder == nil do return
		for &entry in state.encoders {
			if entry.handle == encoder do entry = {}
		}
		for &bindings in state.bindings {
			for &binding in bindings {
				if binding.encoder != encoder do continue
				binding.encoder = nil
				binding.pass = nil
			}
		}
		for &pending in state.resolve_encoder {
			if pending == encoder do pending = nil
		}
	}
}

_gpu_timing_command_encoder :: proc(ctx: ^Context, name: string) -> wg.CommandEncoder {
	assert(ctx != nil)
	assert(ctx.device != nil)
	encoder := wg.DeviceCreateCommandEncoder(ctx.device, &{label = name})
	when GPU_TIMING_DIAGNOSTICS {
		_gpu_timing_diagnostic_encoder_created(&ctx.gpu_timing.diagnostics[0], encoder)
	}
	return encoder
}

_gpu_timing_diagnostic_bind :: proc(
	state: ^Gpu_Timing_Diagnostics,
	slot, pair: u32,
	encoder: wg.CommandEncoder,
	pass: wg.RenderPassEncoder,
	load: wg.LoadOp,
	store: wg.StoreOp,
) {
	assert(state != nil)
	assert(slot < GPU_TIMING_FRAME_SLOTS && pair < GPU_TIMING_MAX_SPANS)
	when GPU_TIMING_DIAGNOSTICS {
		identity: u64
		for entry in state.encoders {
			if entry.handle == encoder && encoder != nil {
				identity = entry.id
				break
			}
		}
		if identity == 0 do state.missing_encoder += 1
		state.bindings[slot][pair] = {
			encoder = encoder,
			pass = pass,
			record = {encoder_id = identity, load = load, store = store},
		}
	}
}

_gpu_timing_diagnostic_draw :: proc(
	state: ^Gpu_Timing_Diagnostics,
	pass: wg.RenderPassEncoder,
	draw: Gpu_Timing_Diagnostic_Draw = {},
) {
	assert(state != nil)
	when GPU_TIMING_DIAGNOSTICS {
		if pass == nil do return
		for &bindings in state.bindings {
			for &binding in bindings {
				if binding.pass == pass && binding.record.submit_ordinal == 0 {
					index := binding.record.draw_count
					if index < u32(len(binding.record.draws)) {
						binding.record.draws[index] = draw
					} else {
						binding.record.draws_dropped += 1
					}
					binding.record.draw_count += 1
				}
			}
		}
	}
}

context_gpu_timing_diagnostic_geometry :: proc(
	ctx: ^Context,
	output: []Gpu_Timing_Diagnostic_Geometry,
) -> u32 {
	assert(ctx != nil)
	when GPU_TIMING_DIAGNOSTICS {
		state := &ctx.gpu_timing.diagnostics[0]
		assert(state.geometry_count <= GPU_TIMING_DIAGNOSTIC_GEOMETRY_CAPACITY)
		return u32(copy(output, state.geometry[:state.geometry_count]))
	} else {
		return 0
	}
}

_gpu_timing_diagnostic_geometry :: proc(
	state: ^Gpu_Timing_Diagnostics,
	vertices: []Vertex,
	indices: []u32,
) -> u32 {
	assert(state != nil)
	assert(state.geometry_count <= GPU_TIMING_DIAGNOSTIC_GEOMETRY_CAPACITY)
	if len(vertices) == 0 ||
	   len(indices) == 0 ||
	   len(vertices) > GPU_TIMING_DIAGNOSTIC_VERTICES_MAX ||
	   len(indices) > GPU_TIMING_DIAGNOSTIC_INDICES_MAX ||
	   state.geometry_count == GPU_TIMING_DIAGNOSTIC_GEOMETRY_CAPACITY {
		state.geometry_dropped += 1
		return 0
	}
	entry := &state.geometry[state.geometry_count]
	entry.vertex_count = u32(len(vertices))
	entry.index_count = u32(len(indices))
	copy(entry.vertices[:], vertices)
	copy(entry.indices[:], indices)
	state.geometry_count += 1
	return state.geometry_count
}

_gpu_timing_diagnostic_batch_draw :: proc(
	ctx: ^Context,
	renderer: ^Renderer,
	pass: wg.RenderPassEncoder,
	count: u32,
) {
	assert(ctx != nil)
	assert(renderer != nil)
	when GPU_TIMING_DIAGNOSTICS {
		if pass != ctx.frame.pass {
			_gpu_timing_diagnostic_draw(&ctx.gpu_timing.diagnostics[0], pass)
			return
		}
		scissor := [4]u32{0, 0, ctx.config.width, ctx.config.height}
		if ctx.frame.scissor_on {
			scissor = {ctx.frame.sc_x, ctx.frame.sc_y, ctx.frame.sc_w, ctx.frame.sc_h}
		}
		state := &ctx.gpu_timing.diagnostics[0]
		retain_geometry := false
		for bindings in state.bindings {
			for binding in bindings {
				if pass != nil &&
				   binding.pass == pass &&
				   binding.record.submit_ordinal == 0 &&
				   binding.record.draw_count < u32(len(binding.record.draws)) {
					retain_geometry = true
				}
			}
		}
		atlas_id, atlas_upload_count, atlas_filter, atlas_known := _gpu_timing_atlas_draw(
			ctx,
			renderer,
		)
		geometry_id: u32
		if retain_geometry {
			if count == u32(len(renderer.indices)) {
				geometry_id = _gpu_timing_diagnostic_geometry(
					state,
					renderer.verts[:],
					renderer.indices[:],
				)
			} else {
				state.geometry_dropped += 1
			}
		}
		_gpu_timing_diagnostic_draw(
			state,
			pass,
			{
				neutral_texture = renderer.neutral_bind != nil &&
				renderer.cur_bind == renderer.neutral_bind,
				atlas_id = atlas_id,
				atlas_upload_count = atlas_upload_count,
				atlas_filter = atlas_filter,
				atlas_known = atlas_known,
				geometry_id = geometry_id,
				projection = renderer.diagnostic_projection,
				projection_bits = transmute([4]u32)renderer.diagnostic_projection,
				projection_known = renderer.ubind != nil &&
				(renderer.cur_u == nil || renderer.cur_u == renderer.ubind) &&
				renderer.diagnostic_projection[0] > 0 &&
				renderer.diagnostic_projection[1] > 0,
				path = .Batch_Builtin,
				known = true,
				indexed = true,
				count = count,
				instances = 1,
				shader_id = 0,
				pipeline_kind = u32(renderer.cur_kind),
				pipeline_style = u32(renderer.cur_blend),
				scissor = scissor,
			},
		)
	}
}

_gpu_timing_diagnostic_submit :: proc(state: ^Gpu_Timing_Diagnostics, encoder: wg.CommandEncoder) {
	assert(state != nil)
	assert(encoder != nil)
	when GPU_TIMING_DIAGNOSTICS {
		state.submit_ordinal += 1
		ensure(state.submit_ordinal != 0)
		for &pending, index in state.resolve_encoder {
			if pending == encoder {
				state.resolve_ordinal[index] = state.submit_ordinal
				identity: u64
				for entry in state.encoders {
					if entry.handle == encoder do identity = entry.id
				}
				if identity == 0 do state.missing_encoder += 1
				for &binding in state.bindings[index] {
					binding.record.resolve_encoder_id = identity
				}
				pending = nil
			}
		}
		for &bindings in state.bindings {
			for &binding in bindings {
				if binding.encoder == encoder && binding.record.submit_ordinal == 0 {
					for &draw in binding.record.draws {
						if draw.atlas_id != 0 {
							draw.atlas_upload_count = state.atlas.upload_count
							draw.atlas_known = draw.atlas_known && state.atlas.dropped == 0
						}
					}
					binding.record.submit_ordinal = state.submit_ordinal
					binding.pass = nil
					binding.encoder = nil
				}
			}
		}
		_gpu_timing_diagnostic_encoder_retire(state, encoder)
	}
}

_gpu_timing_diagnostic_category :: proc(
	state: ^Gpu_Timing_Diagnostics,
	record: Gpu_Timing_Diagnostic,
) {
	assert(state != nil)
	assert(state.category_count <= GPU_TIMING_DIAGNOSTIC_CAPACITY)
	for &category in state.categories[:state.category_count] {
		if _gpu_timing_label_equal(category.label, record.label) &&
		   category.zero_end == (record.end_tick == 0) &&
		   category.has_draws == (record.draw_count > 0) {
			category.count += 1
			return
		}
	}
	if state.category_count == GPU_TIMING_DIAGNOSTIC_CAPACITY {
		state.category_overflow += 1
		return
	}
	state.categories[state.category_count] = {
		label     = record.label,
		zero_end  = record.end_tick == 0,
		has_draws = record.draw_count > 0,
		count     = 1,
		first     = record,
	}
	state.category_count += 1
}

_gpu_timing_diagnostic_collect :: proc(ctx: ^Context, slot_index: int) {
	assert(ctx != nil)
	assert(slot_index >= 0 && slot_index < GPU_TIMING_FRAME_SLOTS)
	when GPU_TIMING_DIAGNOSTICS {
		slot := &ctx.gpu_timing.slots[slot_index]
		diagnostics := &ctx.gpu_timing.diagnostics[0]
		assert(slot.query_count <= GPU_TIMING_QUERY_COUNT)
		diagnostics.collection_next += 1
		ensure(diagnostics.collection_next != 0)
		span_count := slot.query_count / 2
		for pair in 0 ..< span_count {
			previous := diagnostics.previous[slot_index][pair]
			diagnostics.previous[slot_index][pair] = {
				valid      = true,
				epoch      = slot.epoch,
				frame      = slot.frame_index,
				generation = slot.generation,
				begin_tick = slot.ticks[pair * 2],
				end_tick   = slot.ticks[pair * 2 + 1],
			}
			if slot.ticks[pair * 2 + 1] >= slot.ticks[pair * 2] do continue
			record := diagnostics.bindings[slot_index][pair].record
			record.previous = previous
			record.epoch = slot.epoch
			record.frame = slot.frame_index
			record.generation = slot.generation
			record.map_request = slot.submission
			record.resolve_ordinal = diagnostics.resolve_ordinal[slot_index]
			record.begin_tick = slot.ticks[pair * 2]
			record.end_tick = slot.ticks[pair * 2 + 1]
			record.query_begin = pair * 2
			record.slot_index = u32(slot_index)
			record.span_count = span_count
			record.encoder_spans = 0
			for other in 0 ..< span_count {
				if diagnostics.bindings[slot_index][other].record.encoder_id == record.encoder_id {
					record.encoder_spans += 1
				}
			}
			record.label = slot.labels[pair]
			record.callback_status = slot.map_status
			record.collection_id = diagnostics.collection_next
			_gpu_timing_diagnostic_failure(diagnostics, record)
		}
	}
}

_gpu_timing_diagnostic_failure :: proc(
	state: ^Gpu_Timing_Diagnostics,
	record: Gpu_Timing_Diagnostic,
) {
	assert(state != nil)
	assert(state.failure_count <= GPU_TIMING_DIAGNOSTIC_CAPACITY)
	when GPU_TIMING_DIAGNOSTICS {
		_gpu_timing_diagnostic_category(state, record)
		if state.failure_count == GPU_TIMING_DIAGNOSTIC_CAPACITY {
			state.dropped += 1
			return
		}
		state.failures[state.failure_count] = record
		state.failure_count += 1
	}
}

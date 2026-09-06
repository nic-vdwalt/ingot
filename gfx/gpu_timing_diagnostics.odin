package gfx

import wg "vendor:wgpu"

GPU_TIMING_DIAGNOSTICS :: #config(INGOT_GPU_TIMING_DIAGNOSTICS, false)
GPU_TIMING_DIAGNOSTIC_CAPACITY :: 64

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
		record.depth_read_only = depth.depthReadOnly
		record.color_clear = color.clearValue
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
	draw_count:         u32,
	query_begin:        u32,
	slot_index:         u32,
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
	sample_count:       u32,
	callback_status:    wg.MapAsyncStatus,
	collection_id:      u64,
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
	failures:          [GPU_TIMING_DIAGNOSTIC_CAPACITY]Gpu_Timing_Diagnostic,
	failure_count:     u32,
	dropped:           u64,
	encoder_overflow: u64,
	missing_encoder: u64,
	categories:        [GPU_TIMING_DIAGNOSTIC_CAPACITY]Gpu_Timing_Diagnostic_Category,
	category_count:    u32,
	category_overflow: u64,
}

Gpu_Timing_Diagnostics :: struct {
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
	encoder_overflow: u64,
	missing_encoder: u64,
	resolve_encoder:   [GPU_TIMING_FRAME_SLOTS]wg.CommandEncoder,
	resolve_ordinal:   [GPU_TIMING_FRAME_SLOTS]u64,
}

context_gpu_timing_diagnostics :: proc(ctx: ^Context) -> Gpu_Timing_Diagnostic_Snapshot {
	assert(ctx != nil)
	when GPU_TIMING_DIAGNOSTICS {
		state := &ctx.gpu_timing.diagnostics[0]
		assert(state.failure_count <= GPU_TIMING_DIAGNOSTIC_CAPACITY)
		return {
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

_gpu_timing_diagnostic_draw :: proc(state: ^Gpu_Timing_Diagnostics, pass: wg.RenderPassEncoder) {
	assert(state != nil)
	when GPU_TIMING_DIAGNOSTICS {
		if pass == nil do return
		for &bindings in state.bindings {
			for &binding in bindings {
				if binding.pass == pass && binding.record.submit_ordinal == 0 {
					binding.record.draw_count += 1
				}
			}
		}
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
		for pair in 0 ..< slot.query_count / 2 {
			if slot.ticks[pair * 2 + 1] >= slot.ticks[pair * 2] do continue
			record := diagnostics.bindings[slot_index][pair].record
			record.epoch = slot.epoch
			record.frame = slot.frame_index
			record.generation = slot.generation
			record.map_request = slot.submission
			record.resolve_ordinal = diagnostics.resolve_ordinal[slot_index]
			record.begin_tick = slot.ticks[pair * 2]
			record.end_tick = slot.ticks[pair * 2 + 1]
			record.query_begin = pair * 2
			record.slot_index = u32(slot_index)
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

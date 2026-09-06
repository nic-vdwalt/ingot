#+build !js
package gfx

import "core:testing"
import wg "vendor:wgpu"

@(test)
gpu_timing_diagnostics_capture_only_encoded_draws :: proc(t: ^testing.T) {
	when !GPU_TIMING_DIAGNOSTICS do return
	state := new(Gpu_Timing_Diagnostics)
	defer free(state)
	encoder := cast(wg.CommandEncoder)uintptr(1)
	pass := cast(wg.RenderPassEncoder)uintptr(2)
	_gpu_timing_diagnostic_encoder_created(state, encoder)
	_gpu_timing_diagnostic_bind(state, 0, 0, encoder, pass, .Clear, .Store)
	_gpu_timing_diagnostic_bind(state, 0, 1, encoder, nil, .Load, .Store)
	testing.expect_value(t, state.bindings[0][0].record.encoder_id, u64(1))
	testing.expect_value(t, state.bindings[0][1].record.encoder_id, u64(1))
	_gpu_timing_diagnostic_draw(state, nil)
	testing.expect_value(t, state.bindings[0][0].record.draw_count, u32(0))
	_gpu_timing_diagnostic_draw(state, pass)
	_gpu_timing_diagnostic_draw(state, pass)
	_gpu_timing_diagnostic_submit(state, encoder)
	testing.expect_value(t, state.bindings[0][0].record.draw_count, u32(2))
	testing.expect_value(t, state.bindings[0][0].record.submit_ordinal, u64(1))
	_gpu_timing_diagnostic_draw(state, pass)
	testing.expect_value(t, state.bindings[0][0].record.draw_count, u32(2))
	_gpu_timing_diagnostic_encoder_created(state, encoder)
	_gpu_timing_diagnostic_bind(state, 1, 0, encoder, pass, .Load, .Store)
	testing.expect_value(t, state.bindings[1][0].record.encoder_id, u64(2))
	_gpu_timing_diagnostic_submit(state, encoder)
	testing.expect_value(t, state.bindings[1][0].record.submit_ordinal, u64(2))
	testing.expect_value(t, state.bindings[0][0].record.submit_ordinal, u64(1))
	testing.expect_value(t, state.dropped, u64(0))
}

@(test)
gpu_timing_diagnostics_abandoned_encoder_cannot_alias_reuse :: proc(t: ^testing.T) {
	when !GPU_TIMING_DIAGNOSTICS do return
	state := new(Gpu_Timing_Diagnostics)
	defer free(state)
	encoder := cast(wg.CommandEncoder)uintptr(1)
	pass := cast(wg.RenderPassEncoder)uintptr(2)
	_gpu_timing_diagnostic_encoder_created(state, encoder)
	_gpu_timing_diagnostic_bind(state, 0, 0, encoder, pass, .Clear, .Store)
	state.resolve_encoder[0] = encoder
	_gpu_timing_diagnostic_draw(state, pass)
	_gpu_timing_diagnostic_encoder_retire(state, encoder)
	testing.expect(t, state.bindings[0][0].encoder == nil)
	testing.expect(t, state.bindings[0][0].pass == nil)
	testing.expect(t, state.resolve_encoder[0] == nil)
	_gpu_timing_diagnostic_encoder_created(state, encoder)
	_gpu_timing_diagnostic_bind(state, 1, 0, encoder, pass, .Load, .Store)
	_gpu_timing_diagnostic_draw(state, pass)
	state.resolve_encoder[1] = encoder
	_gpu_timing_diagnostic_submit(state, encoder)
	testing.expect_value(t, state.bindings[0][0].record.draw_count, u32(1))
	testing.expect_value(t, state.bindings[0][0].record.submit_ordinal, u64(0))
	testing.expect_value(t, state.resolve_ordinal[0], u64(0))
	testing.expect_value(t, state.bindings[1][0].record.encoder_id, u64(2))
	testing.expect_value(t, state.bindings[1][0].record.submit_ordinal, u64(1))
	testing.expect_value(t, state.resolve_ordinal[1], u64(1))
	testing.expect_value(t, state.bindings[1][0].record.resolve_encoder_id, u64(2))
	testing.expect_value(t, state.bindings[0][0].record.resolve_encoder_id, u64(0))
}

@(test)
gpu_timing_diagnostics_distinguishes_identity_loss :: proc(t: ^testing.T) {
	when GPU_TIMING_DIAGNOSTICS {
		ctx := new(Context)
		defer free(ctx)
		state := &ctx.gpu_timing.diagnostics[0]
		for index in 0 ..< GPU_TIMING_MAX_SPANS {
			_gpu_timing_diagnostic_encoder_created(
				state,
				cast(wg.CommandEncoder)uintptr(index + 1),
			)
		}
		missing := cast(wg.CommandEncoder)uintptr(GPU_TIMING_MAX_SPANS + 1)
		_gpu_timing_diagnostic_encoder_created(state, missing)
		_gpu_timing_diagnostic_bind(state, 0, 0, missing, nil, .Load, .Store)
		state.resolve_encoder[0] = missing
		_gpu_timing_diagnostic_submit(state, missing)
		snapshot := context_gpu_timing_diagnostics(ctx)
		testing.expect_value(t, snapshot.encoder_overflow, u64(1))
		testing.expect_value(t, snapshot.missing_encoder, u64(2))
		testing.expect_value(t, snapshot.dropped, u64(0))
		testing.expect_value(t, state.bindings[0][0].record.resolve_encoder_id, u64(0))
	}
}

@(test)
gpu_timing_diagnostics_bound_failure_storage :: proc(t: ^testing.T) {
	when !GPU_TIMING_DIAGNOSTICS do return
	state := new(Gpu_Timing_Diagnostics)
	defer free(state)
	for index in 0 ..< GPU_TIMING_DIAGNOSTIC_CAPACITY + 2 {
		_gpu_timing_diagnostic_failure(state, {frame = u64(index + 1)})
	}
	testing.expect_value(t, state.failure_count, u32(GPU_TIMING_DIAGNOSTIC_CAPACITY))
	testing.expect_value(t, state.dropped, u64(2))
	testing.expect_value(t, state.failures[0].frame, u64(1))
	testing.expect_value(t, state.category_count, u32(1))
	testing.expect_value(t, state.categories[0].count, u64(66))
	_gpu_timing_diagnostic_failure(state, {label = _gpu_timing_label("late-pass"), frame = 67})
	testing.expect_value(t, state.category_count, u32(2))
	testing.expect_value(t, state.categories[1].first.frame, u64(67))
	for index in 0 ..< GPU_TIMING_DIAGNOSTIC_CAPACITY {
		record := Gpu_Timing_Diagnostic {
			label = {length = 1},
		}
		record.label.bytes[0] = u8(index)
		_gpu_timing_diagnostic_failure(state, record)
	}
	testing.expect_value(t, state.category_count, u32(GPU_TIMING_DIAGNOSTIC_CAPACITY))
	testing.expect_value(t, state.category_overflow, u64(2))
}

@(test)
gpu_timing_diagnostics_collect_all_pairs_and_own_snapshot :: proc(t: ^testing.T) {
	when GPU_TIMING_DIAGNOSTICS {
		ctx := new(Context)
		defer free(ctx)
		slot := &ctx.gpu_timing.slots[0]
		slot.epoch = 7
		slot.frame_index = 42
		slot.generation = 3
		slot.submission = 9
		slot.query_count = 6
		slot.map_status = .Success
		slot.ticks[0] = 100
		slot.ticks[1] = 0
		slot.ticks[2] = 200
		slot.ticks[3] = 210
		slot.ticks[4] = 300
		slot.ticks[5] = 250
		slot.labels[0] = _gpu_timing_label("window")
		slot.labels[2] = _gpu_timing_label("world.ocean")
		_gpu_timing_diagnostic_collect(ctx, 0)
		snapshot := context_gpu_timing_diagnostics(ctx)
		testing.expect_value(t, snapshot.failure_count, u32(2))
		testing.expect_value(t, snapshot.category_count, u32(2))
		testing.expect_value(t, snapshot.failures[1].query_begin, u32(4))
		testing.expect_value(t, snapshot.failures[1].frame, u64(42))
		testing.expect_value(t, snapshot.failures[1].map_request, u64(9))
		testing.expect_value(t, snapshot.failures[1].collection_id, u64(1))
		testing.expect_value(t, snapshot.failures[1].callback_status, wg.MapAsyncStatus.Success)
		ctx.gpu_timing.diagnostics[0] = {}
		slot.ticks[4] = 999
		testing.expect_value(t, snapshot.failures[1].begin_tick, u64(300))
		testing.expect_value(t, snapshot.categories[1].first.begin_tick, u64(300))
	}
}

@(test)
gpu_timing_diagnostics_multisample_attachment :: proc(t: ^testing.T) {
	when GPU_TIMING_DIAGNOSTICS {
		ctx := new(Context)
		defer free(ctx)
		ctx.id = DEFAULT_CONTEXT_ID
		ctx.gpu_timing.active_slot = 0
		encoder := cast(wg.CommandEncoder)uintptr(1)
		_gpu_timing_diagnostic_encoder_created(&ctx.gpu_timing.diagnostics[0], encoder)
		target := Gpu_3D_Target{}
		for antialiasing in Gpu_3D_Antialiasing {
			target.antialiasing = antialiasing
			_gpu_timing_diagnostic_render_pass(
				ctx,
				{querySet = cast(wg.QuerySet)uintptr(2)},
				encoder,
				nil,
				{loadOp = .Clear, storeOp = .Store, clearValue = {0.25, 0.5, 0.75, 1}},
				&target,
				{depthLoadOp = .Clear, depthStoreOp = .Store, depthClearValue = 0.5},
			)
			record := ctx.gpu_timing.diagnostics[0].bindings[0][0].record
			testing.expect_value(t, record.depth_load, wg.LoadOp.Clear)
			testing.expect_value(t, record.depth_store, wg.StoreOp.Store)
			testing.expect_value(t, record.depth_clear, f32(0.5))
			testing.expect_value(t, record.color_clear.r, f64(0.25))
			testing.expect_value(
				t,
				ctx.gpu_timing.diagnostics[0].bindings[0][0].record.sample_count,
				_gpu_3d_sample_count(antialiasing),
			)
		}
	}
}

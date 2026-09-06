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
		record := Gpu_Timing_Diagnostic{label = {length = 1}}
		record.label.bytes[0] = u8(index)
		_gpu_timing_diagnostic_failure(state, record)
	}
	testing.expect_value(t, state.category_count, u32(GPU_TIMING_DIAGNOSTIC_CAPACITY))
	testing.expect_value(t, state.category_overflow, u64(2))
}

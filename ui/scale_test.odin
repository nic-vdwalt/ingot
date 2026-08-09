#+build !js
package ui

import "core:testing"

@(test)
scale_clamps :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	ui_runtime_set_scale(&runtime, 10.0)
	testing.expect_value(t, ui_runtime_scale(&runtime), f32(3.0))
	ui_runtime_set_scale(&runtime, 0.1)
	testing.expect_value(t, ui_runtime_scale(&runtime), f32(0.5))
}

@(test)
scale_sc_rounding :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	ui_runtime_set_scale(&runtime, 2.0)
	testing.expect_value(t, ui_runtime_sc(&runtime, 10), 20)
	testing.expect_value(t, ui_runtime_scf(&runtime, 2.5), f32(5.0))
	ui_runtime_set_scale(&runtime, 1.5)
	testing.expect_value(t, ui_runtime_sc(&runtime, 3), 5)
	testing.expect_value(t, ui_runtime_sc(&runtime, -3), -5)
	testing.expect_value(t, ui_runtime_sc(&runtime, 1), 2)
	testing.expect_value(t, ui_runtime_sc(&runtime, -1), -2)
}

Scale_Reset_State :: struct {
	count: int,
}

scale_reset_count :: proc(data: rawptr) {
	state := cast(^Scale_Reset_State)data
	assert(state != nil, "scale_reset_count: nil state")
	state.count += 1
}

@(test)
scale_change_resets_backend_once :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	state: Scale_Reset_State
	runtime.text_backend = {data = &state, reset = scale_reset_count}

	ui_runtime_set_scale(&runtime, 2)
	testing.expect_value(t, state.count, 1)
	testing.expect_value(t, runtime.generation, u64(1))
	ui_runtime_set_scale(&runtime, 2)
	testing.expect_value(t, state.count, 1)
	testing.expect_value(t, runtime.generation, u64(1))
	ui_runtime_set_scale(&runtime, 3)
	testing.expect_value(t, state.count, 2)
	testing.expect_value(t, runtime.generation, u64(2))
}

@(test)
scale_noop_when_unchanged :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	ui_runtime_set_scale(&runtime, 2.0)
	before := runtime.generation
	ui_runtime_set_scale(&runtime, 2.0)
	testing.expect_value(t, runtime.generation, before)
	testing.expect_value(t, runtime.metrics.FONT_SIZE_BODY, i32(32))
}

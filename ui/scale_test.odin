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
	testing.expect_value(t, runtime.metrics.FONT_SIZE, i32(32))
}

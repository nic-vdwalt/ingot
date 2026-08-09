#+build !js
package ui

import "core:math"
import "core:testing"

Dpi_Hook_State :: struct {
	invalidations: int,
}

@(private = "file")
dpi_hook_state: ^Dpi_Hook_State

@(private = "file")
dpi_invalidation_count :: proc() {
	assert(dpi_hook_state != nil, "dpi_invalidation_count: nil state")
	dpi_hook_state.invalidations += 1
}

@(test)
dpi_apply_normalizes_invalid_platform_value :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)

	ui_runtime_apply_platform_dpi(&runtime, dpi_scale = math.nan_f32())
	testing.expect_value(t, runtime.dpi_last, f32(1))
	testing.expect(t, !ui_runtime_dpi_refresh(&runtime, dpi_scale = math.nan_f32()))
	testing.expect_value(t, runtime.dpi_last, f32(1))
}

@(test)
dpi_refresh_unchanged_is_noop :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	ui_runtime_apply_platform_dpi(&runtime, dpi_scale = 1.5)
	generation := runtime.generation

	testing.expect(t, !ui_runtime_dpi_refresh(&runtime, dpi_scale = 1.5))
	testing.expect_value(t, runtime.generation, generation)
}

@(test)
dpi_refresh_invalid_transition_normalizes_once :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	ui_runtime_apply_platform_dpi(&runtime, dpi_scale = 2)

	testing.expect(t, ui_runtime_dpi_refresh(&runtime, dpi_scale = math.nan_f32()))
	generation := runtime.generation
	testing.expect_value(t, runtime.dpi_last, f32(1))
	testing.expect(t, !ui_runtime_dpi_refresh(&runtime, dpi_scale = math.nan_f32()))
	testing.expect_value(t, runtime.generation, generation)
}

@(test)
dpi_refresh_invalidates_each_effect_once :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	state: Dpi_Hook_State
	dpi_hook_state = &state
	defer {dpi_hook_state = nil}
	ui_runtime_set_scale_hooks(&runtime, nil, dpi_invalidation_count)
	ui_runtime_apply_platform_dpi(&runtime, dpi_scale = 1)
	state.invalidations = 0
	generation := runtime.generation

	testing.expect(t, ui_runtime_dpi_refresh(&runtime, dpi_scale = 2))
	testing.expect_value(t, state.invalidations, 1)
	testing.expect_value(t, runtime.generation, generation + 1)
	when ODIN_OS == .Darwin {
		testing.expect_value(t, runtime.scale, f32(1))
		testing.expect_value(t, runtime.text.font_dpi, f32(2))
	} else {
		testing.expect_value(t, runtime.scale, f32(2))
		testing.expect_value(t, runtime.text.font_dpi, f32(1))
	}
}

@(test)
dpi_refresh_respects_explicit_user_scale :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	ui_runtime_apply_platform_dpi(&runtime, user_scale = 1.5, dpi_scale = 1)
	generation := runtime.generation

	testing.expect(t, ui_runtime_dpi_refresh(&runtime, user_scale = 1.5, dpi_scale = 2))
	testing.expect_value(t, runtime.scale, f32(1.5))
	when ODIN_OS == .Darwin {
		testing.expect_value(t, runtime.generation, generation + 1)
		testing.expect_value(t, runtime.text.font_dpi, f32(2))
	} else {
		testing.expect_value(t, runtime.generation, generation)
		testing.expect_value(t, runtime.text.font_dpi, f32(1))
	}
}

package ui

auto_scale :: proc(input: ^Ui_Input = nil) -> f32 {
	when ODIN_OS == .Darwin || ODIN_OS == .JS {
		return 1
	}
	if input == nil || input.dpi_scale <= 0 do return 1
	return input.dpi_scale
}

ui_runtime_apply_platform_dpi :: proc(runtime: ^Ui_Runtime, user_scale: f32 = 0, dpi_scale: f32 = 1) {
	assert(runtime != nil && runtime.initialized, "apply_platform_dpi: invalid runtime")
	dpi := dpi_scale if dpi_scale > 0 else 1
	runtime.dpi_last = dpi
	when ODIN_OS == .Darwin || ODIN_OS == .JS {
		ui_runtime_set_scale(runtime, user_scale if user_scale > 0 else 1)
		set_font_dpi_with(&runtime.text, dpi)
	} else {
		ui_runtime_set_scale(runtime, user_scale if user_scale > 0 else dpi)
		set_font_dpi_with(&runtime.text, 1)
	}
}

ui_runtime_dpi_refresh :: proc(runtime: ^Ui_Runtime, user_scale: f32 = 0, dpi_scale: f32 = 1) -> bool {
	assert(runtime != nil && runtime.initialized, "dpi_refresh: invalid runtime")
	dpi := dpi_scale
	if dpi <= 0 do return false
	if runtime.dpi_last == 0 {
		runtime.dpi_last = dpi
		return false
	}
	if dpi == runtime.dpi_last do return false
	runtime.dpi_last = dpi
	when ODIN_OS == .Darwin || ODIN_OS == .JS {
		set_font_dpi_with(&runtime.text, dpi)
		reset_font_atlases_with(&runtime.text)
	} else {
		if user_scale <= 0 do ui_runtime_set_scale(runtime, dpi)
		reset_font_atlases_with(&runtime.text)
		ui_runtime_invalidate_scale_caches(runtime)
	}
	runtime.generation += 1
	return true
}

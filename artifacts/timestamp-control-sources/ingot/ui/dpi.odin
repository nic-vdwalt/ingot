package ui

@(private)
platform_dpi_normalize :: proc "contextless" (value: f32) -> f32 {
	if !scale_f32_is_finite(value) || value <= 0 do return 1
	return value
}

auto_scale :: proc(input: ^Ui_Input = nil) -> f32 {
	when ODIN_OS == .Darwin || ODIN_OS == .JS {
		return 1
	}
	if input == nil do return 1
	return platform_dpi_normalize(input.dpi_scale)
}

ui_runtime_apply_platform_dpi :: proc(
	runtime: ^Ui_Runtime,
	user_scale: f32 = 0,
	dpi_scale: f32 = 1,
) {
	assert(runtime != nil, "ui_runtime_apply_platform_dpi: nil runtime")
	assert(runtime.initialized, "ui_runtime_apply_platform_dpi: runtime not initialized")
	assert(scale_f32_is_finite(user_scale), "ui_runtime_apply_platform_dpi: non-finite user scale")
	assert(user_scale >= 0, "ui_runtime_apply_platform_dpi: negative user scale")
	dpi := platform_dpi_normalize(dpi_scale)
	runtime.dpi_last = dpi
	when ODIN_OS == .Darwin || ODIN_OS == .JS {
		ui_runtime_set_scale(runtime, user_scale if user_scale > 0 else 1)
		set_font_dpi_with(&runtime.text, dpi)
	} else {
		ui_runtime_set_scale(runtime, user_scale if user_scale > 0 else dpi)
		set_font_dpi_with(&runtime.text, 1)
	}
}

ui_runtime_dpi_refresh :: proc(
	runtime: ^Ui_Runtime,
	user_scale: f32 = 0,
	dpi_scale: f32 = 1,
) -> bool {
	assert(runtime != nil, "ui_runtime_dpi_refresh: nil runtime")
	assert(runtime.initialized, "ui_runtime_dpi_refresh: runtime not initialized")
	assert(scale_f32_is_finite(user_scale), "ui_runtime_dpi_refresh: non-finite user scale")
	assert(user_scale >= 0, "ui_runtime_dpi_refresh: negative user scale")
	dpi := platform_dpi_normalize(dpi_scale)
	if runtime.dpi_last == 0 {
		runtime.dpi_last = dpi
		return false
	}
	if dpi == runtime.dpi_last do return false
	runtime.dpi_last = dpi
	when ODIN_OS == .Darwin || ODIN_OS == .JS {
		set_font_dpi_with(&runtime.text, dpi)
		ui_runtime_invalidate_scale_caches(runtime)
		runtime.generation += 1
	} else {
		if user_scale <= 0 do ui_runtime_set_scale(runtime, dpi)
	}
	return true
}

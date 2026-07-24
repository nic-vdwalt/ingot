// LIB-CANDIDATE: imports only core:* and ingot:gfx.
package ui


auto_scale :: proc() -> f32 {
	when ODIN_OS == .Darwin || ODIN_OS == .JS {
		return 1.0
	} else {
		s := rl.GetWindowScaleDPI().x
		return s if s > 0 else 1.0
	}
}

ui_runtime_apply_platform_dpi :: proc(runtime: ^Ui_Runtime, user_scale: f32 = 0) {
	assert(runtime != nil && runtime.initialized, "apply_platform_dpi: invalid runtime")
	dpi := rl.GetWindowScaleDPI().x
	if dpi <= 0 do dpi = 1.0
	runtime.dpi_last = dpi
	when ODIN_OS == .Darwin || ODIN_OS == .JS {
		ui_runtime_set_scale(runtime, user_scale if user_scale > 0 else 1.0)
		set_font_dpi_with(&runtime.text, dpi)
	} else {
		ui_runtime_set_scale(runtime, user_scale if user_scale > 0 else dpi)
		set_font_dpi_with(&runtime.text, 1.0)
	}
}

ui_runtime_dpi_refresh :: proc(runtime: ^Ui_Runtime, user_scale: f32 = 0) -> bool {
	assert(runtime != nil && runtime.initialized, "dpi_refresh: invalid runtime")
	dpi := rl.GetWindowScaleDPI().x
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

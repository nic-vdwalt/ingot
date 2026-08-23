package ui

Text_Measure_Proc :: proc(data: rawptr, font: Font_Id, text: string, size, spacing: f32) -> Vec2
Text_Font_Proc :: proc(data: rawptr, size: i32) -> Font_Id
Text_Has_Glyph_Proc :: proc(data: rawptr, font: Font_Id, value: rune) -> bool
Text_Reset_Proc :: proc(data: rawptr)

Text_Backend :: struct {
	data:          rawptr,
	font_for_size: Text_Font_Proc,
	measure:       Text_Measure_Proc,
	has_glyph:     Text_Has_Glyph_Proc,
	reset:         Text_Reset_Proc,
}

text_backend_valid :: proc(backend: Text_Backend) -> bool {
	return backend.font_for_size != nil && backend.measure != nil
}

ui_runtime_set_text_backend :: proc(runtime: ^Ui_Runtime, backend: Text_Backend) {
	assert(runtime != nil && runtime.initialized, "ui_runtime_set_text_backend: invalid runtime")
	assert(text_backend_valid(backend), "ui_runtime_set_text_backend: invalid backend")
	clear_measure_cache_with(&runtime.text)
	clear_wrap_cache_with(&runtime.text)
	runtime.text_backend = backend
	assert(runtime.font_epoch < max(u64), "ui_runtime_set_text_backend: epoch exhausted")
	runtime.font_epoch += 1
}

ui_runtime_set_backend_measure_cache_enabled :: proc(runtime: ^Ui_Runtime, enabled: bool) {
	assert(runtime != nil && runtime.initialized, "backend measure cache: invalid runtime")
	if runtime.text.backend_measure_cache_enabled == enabled do return
	clear_measure_cache_with(&runtime.text)
	runtime.text.backend_measure_cache_enabled = enabled
}

text_backend_font :: proc(backend: Text_Backend, size: i32) -> Font_Id {
	assert(text_backend_valid(backend), "text_backend_font: invalid backend")
	assert(size > 0, "text_backend_font: invalid size")
	return backend.font_for_size(backend.data, size)
}

text_backend_measure :: proc(
	backend: Text_Backend,
	font: Font_Id,
	text: string,
	size, spacing: f32,
) -> Vec2 {
	assert(text_backend_valid(backend), "text_backend_measure: invalid backend")
	assert(size > 0, "text_backend_measure: invalid size")
	return backend.measure(backend.data, font, text, size, spacing)
}

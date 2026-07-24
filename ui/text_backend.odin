package ui

Text_Measure_Proc :: proc(data: rawptr, font: Font_Id, text: string, size, spacing: f32) -> Vec2
Text_Font_Proc :: proc(data: rawptr, size: i32) -> Font_Id
Text_Reset_Proc :: proc(data: rawptr)

Text_Backend :: struct {
	data:          rawptr,
	font_for_size: Text_Font_Proc,
	measure:       Text_Measure_Proc,
	reset:         Text_Reset_Proc,
}

text_backend_valid :: proc(backend: Text_Backend) -> bool {
	return backend.font_for_size != nil && backend.measure != nil
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

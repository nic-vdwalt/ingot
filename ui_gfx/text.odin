package ui_gfx

import "core:strings"
import rl "ingot:gfx"
import "ingot:ui"

adapter_font :: proc(adapter: ^Adapter, id: ui.Font_Id) -> (rl.Font, bool) {
	assert(adapter != nil, "adapter_font: nil adapter")
	index := int(id)
	if index <= 0 || index > adapter.font_count do return {}, false
	return adapter.fonts[index - 1], true
}

adapter_register_font :: proc(adapter: ^Adapter, size: i32, font: rl.Font) -> ui.Font_Id {
	assert(adapter != nil && adapter.initialized, "adapter_register_font: invalid adapter")
	assert(size > 0 && font.glyphCount > 0, "adapter_register_font: invalid font")
	for index in 0 ..< adapter.font_count {
		if adapter.font_sizes[index] == size do return ui.Font_Id(index + 1)
	}
	assert(adapter.font_count < FONT_CAP, "adapter_register_font: font limit")
	index := adapter.font_count
	adapter.fonts[index] = font
	adapter.font_sizes[index] = size
	adapter.font_count += 1
	return ui.Font_Id(index + 1)
}

adapter_text_backend :: proc(adapter: ^Adapter) -> ui.Text_Backend {
	assert(adapter != nil && adapter.initialized, "adapter_text_backend: invalid adapter")
	return {
		data = adapter,
		font_for_size = adapter_font_for_size,
		measure = adapter_measure,
		reset = adapter_reset_fonts,
	}
}

adapter_font_for_size :: proc(data: rawptr, size: i32) -> ui.Font_Id {
	adapter := cast(^Adapter)data
	assert(adapter != nil && adapter.initialized, "adapter_font_for_size: invalid adapter")
	for index in 0 ..< adapter.font_count {
		if adapter.font_sizes[index] == size do return ui.Font_Id(index + 1)
	}
	return ui.Font_Id(0)
}

adapter_measure :: proc(
	data: rawptr,
	font_id: ui.Font_Id,
	text: string,
	size, spacing: f32,
) -> ui.Vec2 {
	adapter := cast(^Adapter)data
	assert(adapter != nil && adapter.initialized, "adapter_measure: invalid adapter")
	font, ok := adapter_font(adapter, font_id)
	if !ok do return {f32(len(text)) * size / 2, size}
	value := strings.clone_to_cstring(text, context.temp_allocator)
	return vec_to_ui(rl.MeasureTextEx(font, value, size, spacing))
}

adapter_reset_fonts :: proc(data: rawptr) {
	adapter := cast(^Adapter)data
	assert(adapter != nil && adapter.initialized, "adapter_reset_fonts: invalid adapter")
	for index in 0 ..< adapter.font_count {
		if adapter.fonts[index].glyphCount > 0 do rl.UnloadFont(adapter.fonts[index])
	}
	adapter.font_count = 0
}

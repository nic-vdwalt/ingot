package ui_gfx

import "core:strings"
import rl "ingot:gfx"
import "ingot:ui"

FONT_DATA := #load("../assets/fonts/JetBrainsMono-Regular.ttf")

Codepoint_Range :: struct {
	start: rune,
	end:   rune,
}

CODEPOINT_RANGES :: [?]Codepoint_Range {
	{0x0020, 0x007E},
	{0x00A0, 0x00FF},
	{0x0100, 0x024F},
	{0x2000, 0x206F},
	{0x2190, 0x21FF},
	{0x2200, 0x22FF},
	{0x2300, 0x23FF},
	{0x2500, 0x257F},
	{0x2580, 0x259F},
	{0x25A0, 0x25FF},
	{0x2600, 0x26FF},
	{0x2700, 0x27BF},
	{0x2800, 0x28FF},
	{0x2B00, 0x2B73},
}

adapter_text_init :: proc(adapter: ^Adapter) {
	assert(adapter != nil && adapter.initialized, "adapter_text_init: invalid adapter")
	total := 0
	for value in CODEPOINT_RANGES {
		total += int(value.end - value.start) + 1
	}
	adapter.font_codepoints = make([]rune, total)
	index := 0
	for value in CODEPOINT_RANGES {
		for codepoint := value.start; codepoint <= value.end; codepoint += 1 {
			adapter.font_codepoints[index] = codepoint
			index += 1
		}
	}
}

adapter_font :: proc(adapter: ^Adapter, id: ui.Font_Id) -> (rl.Font, bool) {
	assert(adapter != nil, "adapter_font: nil adapter")
	index := int(id)
	if index <= 0 || index > adapter.font_count do return {}, false
	font := adapter.fonts[index - 1]
	return font, font.glyphCount > 0
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
	assert(size > 0, "adapter_font_for_size: invalid size")
	for index in 0 ..< adapter.font_count {
		if adapter.font_sizes[index] == size do return ui.Font_Id(index + 1)
	}
	assert(adapter.font_count < FONT_CAP, "adapter_font_for_size: font limit")
	pixel_size := i32(f32(size) * adapter.font_dpi + 0.5)
	if pixel_size < 1 do pixel_size = 1
	font := rl.context_load_font_from_memory(
		adapter.gfx_context,
		".ttf",
		raw_data(FONT_DATA),
		i32(len(FONT_DATA)),
		pixel_size,
		raw_data(adapter.font_codepoints),
		i32(len(adapter.font_codepoints)),
	)
	assert(font.glyphCount > 0, "adapter_font_for_size: bundled font failed to load")
	rl.context_set_texture_filter(adapter.gfx_context, font.texture, .BILINEAR)
	return adapter_register_font(adapter, size, font)
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
	assert(ok, "adapter_measure: invalid font")
	value := strings.clone_to_cstring(text, context.temp_allocator)
	return vec_to_ui(rl.context_measure_text(adapter.gfx_context, font, value, size, spacing))
}

adapter_set_font_dpi :: proc(adapter: ^Adapter, scale: f32) {
	assert(adapter != nil && adapter.initialized, "adapter_set_font_dpi: invalid adapter")
	dpi := scale if scale > 0 else 1
	if dpi == adapter.font_dpi do return
	adapter_reset_fonts(adapter)
	adapter.font_dpi = dpi
}

adapter_reset_fonts :: proc(data: rawptr) {
	adapter := cast(^Adapter)data
	assert(adapter != nil && adapter.initialized, "adapter_reset_fonts: invalid adapter")
	assert(adapter.gfx_context != nil, "adapter_reset_fonts: nil graphics context")
	for index in 0 ..< adapter.font_count {
		rl.context_unload_font(adapter.gfx_context, adapter.fonts[index])
		adapter.fonts[index] = {}
		adapter.font_sizes[index] = 0
	}
	adapter.font_count = 0
}

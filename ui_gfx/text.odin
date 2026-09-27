package ui_gfx

import "core:math"
import "core:strings"
import rl "ingot:gfx"
import "ingot:ui"

FONT_DATA := #load("../assets/fonts/JetBrainsMono-Regular.ttf")
PIXEL_FONT_DATA := #load("../assets/fonts/PixelOperator.ttf")

// PIXEL_FONT_NATIVE_PX is Pixel Operator's design em in device pixels: its
// 1600-unit em is drawn on 100-unit squares, so a 16 px bake puts every
// outline edge on a pixel boundary. The atlas is only ever baked at whole
// multiples of it; any other size would rasterise edges as grey coverage.
PIXEL_FONT_NATIVE_PX :: 16
#assert(PIXEL_FONT_NATIVE_PX == ui.PIXEL_FONT_GRID_PX)

Codepoint_Range :: struct {
	start: rune,
	end:   rune,
}

// The first EAGER_CODEPOINT_RANGE_COUNT ranges (ASCII, Latin-1 Supplement,
// General Punctuation) are the ones web builds bake up front.
CODEPOINT_RANGES :: [?]Codepoint_Range {
	{0x0020, 0x007E},
	{0x00A0, 0x00FF},
	{0x2000, 0x206F},
	{0x0100, 0x024F},
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

EAGER_CODEPOINT_RANGE_COUNT :: 3
#assert(EAGER_CODEPOINT_RANGE_COUNT <= len(CODEPOINT_RANGES))

adapter_text_init :: proc(adapter: ^Adapter) {
	assert(adapter != nil && adapter.initialized, "adapter_text_init: invalid adapter")
	// On web only the eager ranges are baked when an atlas is created; the
	// rest bake lazily on first draw/measure (gfx/text.odin _bake_glyph).
	// Baking every range up front made each new font size a multi-thousand
	// glyph burst, which iOS answered by killing the tab.
	eager := EAGER_CODEPOINT_RANGE_COUNT when ODIN_OS == .JS else len(CODEPOINT_RANGES)
	ranges := CODEPOINT_RANGES
	total := 0
	for value in ranges[:eager] {
		total += int(value.end - value.start) + 1
	}
	adapter.font_codepoints = make([]rune, total)
	index := 0
	for value in ranges[:eager] {
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

adapter_register_font :: proc(
	adapter: ^Adapter,
	face: ui.Font_Face,
	size: i32,
	font: rl.Font,
) -> ui.Font_Id {
	assert(adapter != nil && adapter.initialized, "adapter_register_font: invalid adapter")
	assert(size > 0 && font.glyphCount > 0, "adapter_register_font: invalid font")
	for index in 0 ..< adapter.font_count {
		if adapter.font_faces[index] == face &&
		   adapter.font_sizes[index] == size &&
		   adapter.fonts[index]._atlas == font._atlas {
			return ui.Font_Id(index + 1)
		}
	}
	if adapter.font_count >= FONT_CAP do return adapter_closest_font(adapter, face, size)
	index := adapter.font_count
	adapter.fonts[index] = font
	adapter.font_sizes[index] = size
	adapter.font_faces[index] = face
	adapter.font_count += 1
	return ui.Font_Id(index + 1)
}

// adapter_closest_font is the at-capacity fallback: the loaded font of the
// same face nearest in size. A face switch resets the table, so a full table
// always holds at least one font of the current face; Font_Id(1) is only the
// defensive answer if a caller interleaves faces within one frame.
@(private = "file")
adapter_closest_font :: proc(adapter: ^Adapter, face: ui.Font_Face, size: i32) -> ui.Font_Id {
	assert(adapter != nil && adapter.font_count > 0, "adapter_closest_font: empty table")
	assert(size > 0, "adapter_closest_font: invalid size")
	closest := -1
	closest_distance := max(i32)
	for index in 0 ..< adapter.font_count {
		if adapter.font_faces[index] != face do continue
		distance := abs(adapter.font_sizes[index] - size)
		if distance < closest_distance {
			closest = index
			closest_distance = distance
		}
	}
	if closest < 0 do return ui.Font_Id(1)
	return ui.Font_Id(closest + 1)
}

adapter_text_backend :: proc(adapter: ^Adapter) -> ui.Text_Backend {
	assert(adapter != nil && adapter.initialized, "adapter_text_backend: invalid adapter")
	return {
		data = adapter,
		font_for_size = adapter_font_for_size,
		measure = adapter_measure,
		has_glyph = adapter_has_glyph,
		metrics = adapter_metrics,
		reset = adapter_reset_fonts,
	}
}

adapter_font_for_size :: proc(data: rawptr, face: ui.Font_Face, size: i32) -> ui.Font_Id {
	adapter := cast(^Adapter)data
	assert(adapter != nil && adapter.initialized, "adapter_font_for_size: invalid adapter")
	assert(size > 0, "adapter_font_for_size: invalid size")
	for index in 0 ..< adapter.font_count {
		if adapter.font_faces[index] == face && adapter.font_sizes[index] == size {
			return ui.Font_Id(index + 1)
		}
	}
	if adapter.font_count >= FONT_CAP do return adapter_closest_font(adapter, face, size)
	pixel_size := i32(f32(size) * adapter.font_dpi + 0.5)
	if pixel_size < 1 do pixel_size = 1
	file_data := FONT_DATA
	filter := rl.TextureFilter.BILINEAR
	if face == .Pixel {
		pixel_size = adapter_pixel_bake_size(pixel_size)
		file_data = PIXEL_FONT_DATA
		// Nearest sampling keeps each font pixel a hard square when the
		// DPI transform maps one atlas texel to several device pixels.
		filter = .POINT
	}
	font := rl.context_load_font_from_memory(
		adapter.gfx_context,
		".ttf",
		raw_data(file_data),
		i32(len(file_data)),
		pixel_size,
		raw_data(adapter.font_codepoints),
		i32(len(adapter.font_codepoints)),
	)
	if font.glyphCount <= 0 do return 0
	rl.context_set_texture_filter(adapter.gfx_context, font.texture, filter)
	return adapter_register_font(adapter, face, size, font)
}

// adapter_pixel_bake_size rounds a device size to the nearest whole multiple
// of the pixel face's native grid, never below one grid.
adapter_pixel_bake_size :: proc(pixel_size: i32) -> i32 {
	assert(pixel_size > 0, "adapter_pixel_bake_size: invalid size")
	steps := max(1, (pixel_size + PIXEL_FONT_NATIVE_PX / 2) / PIXEL_FONT_NATIVE_PX)
	result := steps * PIXEL_FONT_NATIVE_PX
	assert(result % PIXEL_FONT_NATIVE_PX == 0, "adapter_pixel_bake_size: off grid")
	return result
}

// adapter_font_snaps reports whether text in this font must land on whole
// device pixels. Only the pixel face does: a smooth face is anti-aliased and
// benefits from sub-pixel placement, a pixel face is smeared by it.
adapter_font_snaps :: proc(adapter: ^Adapter, id: ui.Font_Id) -> bool {
	assert(adapter != nil, "adapter_font_snaps: nil adapter")
	index := int(id)
	if index <= 0 || index > adapter.font_count do return false
	return adapter.font_faces[index - 1] == .Pixel
}

// adapter_snap_point rounds a logical point to the nearest device pixel.
adapter_snap_point :: proc(adapter: ^Adapter, point: ui.Vec2) -> ui.Vec2 {
	assert(adapter != nil, "adapter_snap_point: nil adapter")
	dpi := adapter.font_dpi if adapter.font_dpi > 0 else 1
	assert(dpi > 0, "adapter_snap_point: invalid dpi")
	return {math.round(point.x * dpi) / dpi, math.round(point.y * dpi) / dpi}
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
	if !ok do return {}
	for byte in transmute([]u8)text do if byte == 0 do return {}
	value := strings.clone_to_cstring(text, context.temp_allocator)
	return vec_to_ui(rl.context_measure_text(adapter.gfx_context, font, value, size, spacing))
}

adapter_metrics :: proc(data: rawptr, font_id: ui.Font_Id, size: f32) -> (ui.Text_Metrics, bool) {
	adapter := cast(^Adapter)data
	assert(adapter != nil && adapter.initialized, "adapter_metrics: invalid adapter")
	assert(size > 0, "adapter_metrics: invalid size")
	font, font_ok := adapter_font(adapter, font_id)
	if !font_ok do return {}, false
	metrics, metrics_ok := rl.context_font_metrics(adapter.gfx_context, font, size)
	if !metrics_ok do return {}, false
	return {
			ascent = metrics.ascent,
			descent = metrics.descent,
			line_gap = metrics.line_gap,
			line_advance = metrics.line_advance,
		},
		true
}

adapter_has_glyph :: proc(data: rawptr, font_id: ui.Font_Id, value: rune) -> bool {
	adapter := cast(^Adapter)data
	assert(adapter != nil && adapter.initialized, "adapter_has_glyph: invalid adapter")
	assert(value >= 0 && value <= 0x10FFFF, "adapter_has_glyph: invalid codepoint")
	font, ok := adapter_font(adapter, font_id)
	if !ok do return false
	return rl.context_font_has_glyph(adapter.gfx_context, font, value)
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
		adapter.font_faces[index] = .Mono
	}
	adapter.font_count = 0
}

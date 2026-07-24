// LIB-CANDIDATE: imports only core:* and ingot:gfx.
package ui

import "core:strings"


FONT_DATA := #load("../assets/fonts/JetBrainsMonoNerdFontMono-Regular.ttf")

Measure_Key :: struct {
	text: string,
	size: i32,
}

Measure_Entry :: struct {
	width: i32,
	stamp: u64,
}

Text_System :: struct {
	font_loaded:             bool,
	font_dpi:                f32,
	font_codepoints:         []rune,
	measure_cache:           map[Measure_Key]Measure_Entry,
	measure_cache_evictions: int,
	measure_stamp:           u64,
	measure_backend:         proc(text: cstring, size: i32) -> i32,
	wrap_cache:              map[Wrap_Key]Wrap_Entry,
	wrap_cache_evictions:    int,
	wrap_stamp:              u64,
}

text_system_init :: proc(system: ^Text_System) {
	assert(system != nil)
	assert(!system.font_loaded)
	if system.font_dpi <= 0 do system.font_dpi = 1.0
	total := 0
	for r in CODEPOINT_RANGES {
		total += int(r.end - r.start) + 1
	}
	system.font_codepoints = make([]rune, total)
	idx := 0
	for r in CODEPOINT_RANGES {
		for cp := r.start; cp <= r.end; cp += 1 {
			system.font_codepoints[idx] = cp
			idx += 1
		}
	}
	system.font_loaded = true
}

set_font_dpi_with :: proc(system: ^Text_System, scale: f32) {
	assert(system != nil)
	system.font_dpi = scale if scale > 0 else 1.0
}

reset_font_atlases_with :: proc(system: ^Text_System) {
	assert(system != nil)
	if !system.font_loaded do return
}

measure_cache_stats_with :: proc(system: ^Text_System) -> (entries: int, evictions: int) {
	assert(system != nil)
	return len(system.measure_cache), system.measure_cache_evictions
}

set_measure_backend_with :: proc(system: ^Text_System, fn: proc(text: cstring, size: i32) -> i32) {
	assert(system != nil)
	system.measure_backend = fn
	clear_measure_cache_with(system)
	clear_wrap_cache_with(system)
}

@(private)
measure_raw_with :: proc(system: ^Text_System, text: cstring, size: i32) -> i32 {
	assert(system != nil)
	if system.measure_backend != nil do return system.measure_backend(text, size)
	return i32(len(string(text))) * size / 2
}

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
	{0x23FB, 0x23FE},
	{0x2B58, 0x2B58},
	{0xE000, 0xE00A},
	{0xE0A0, 0xE0A3},
	{0xE0B0, 0xE0D4},
	{0xE200, 0xE2A9},
	{0xE300, 0xE3E3},
	{0xE5FA, 0xE6B5},
	{0xE700, 0xE7C5},
	{0xEA60, 0xEC1E},
	{0xED00, 0xEFC1},
	{0xF000, 0xF2FF},
	{0xF300, 0xF375},
	{0xF400, 0xF533},
}

clear_measure_cache_with :: proc(system: ^Text_System) {
	assert(system != nil)
	for key in system.measure_cache {
		delete(key.text)
	}
	delete(system.measure_cache)
	system.measure_cache = nil
	system.measure_stamp = 0
}

text_system_destroy :: proc(system: ^Text_System) {
	assert(system != nil)
	if system.font_loaded {
		reset_font_atlases_with(system)
		delete(system.font_codepoints)
	}
	clear_measure_cache_with(system)
	clear_wrap_cache_with(system)
	system^ = {}
}

draw_text_with :: proc(system: ^Text_System, text: cstring, x, y, size: i32, color: Color) {
	assert(system != nil)
}

draw_text_frame :: proc(frame: ^Ui_Frame, text: cstring, x, y, size: i32, color: Color) {
	assert(size > 0, "draw_text_frame: invalid size")
	font := Font_Id(0)
	if text_backend_valid(frame.runtime.text_backend) do font = text_backend_font(frame.runtime.text_backend, size)
	draw_cstring_command(frame, text, x, y, size, color, font)
}

MEASURE_CACHE_MAX :: 8192
MEASURE_CACHE_MAX_KEY_LEN :: 256

@(private)
measure_evict_oldest :: proc(system: ^Text_System) {
	assert(system != nil)
	assert(len(system.measure_cache) > 0)
	oldest: Measure_Key
	oldest_stamp := max(u64)
	for key, entry in system.measure_cache {
		if entry.stamp < oldest_stamp {
			oldest = key
			oldest_stamp = entry.stamp
		}
	}
	delete_key(&system.measure_cache, oldest)
	delete(oldest.text)
	system.measure_cache_evictions += 1
}

measure_text_with :: proc(system: ^Text_System, text: cstring, size: i32) -> i32 {
	assert(system != nil)
	assert(size > 0)
	if !system.font_loaded do return measure_raw_with(system, text, size)
	key := Measure_Key {
		text = string(text),
		size = size,
	}
	if entry, ok := system.measure_cache[key]; ok {
		system.measure_stamp += 1
		entry.stamp = system.measure_stamp
		system.measure_cache[key] = entry
		return entry.width
	}
	width := measure_raw_with(system, text, size)
	if len(key.text) <= MEASURE_CACHE_MAX_KEY_LEN {
		if len(system.measure_cache) >= MEASURE_CACHE_MAX do measure_evict_oldest(system)
		system.measure_stamp += 1
		owned := Measure_Key {
			text = strings.clone(string(text)),
			size = size,
		}
		system.measure_cache[owned] = Measure_Entry {
			width = width,
			stamp = system.measure_stamp,
		}
	}
	return width
}

measure_text_frame :: proc(frame: ^Ui_Frame, text: cstring, size: i32) -> i32 {
	assert(size > 0, "measure_text_frame: invalid size")
	return measure_text_with(ui_frame_text(frame), text, size)
}

rune_width_with :: proc(system: ^Text_System, value: rune, size: i32) -> i32 {
	assert(system != nil)
	buf: [5]u8
	n := 0
	codepoint := u32(value)
	switch {
	case codepoint <= 0x7F:
		buf[0] = u8(codepoint); n = 1
	case codepoint <= 0x7FF:
		buf[0] = u8(0xC0 | (codepoint >> 6)); buf[1] = u8(0x80 | (codepoint & 0x3F)); n = 2
	case codepoint <= 0xFFFF:
		buf[0] = u8(0xE0 | (codepoint >> 12)); buf[1] = u8(0x80 | ((codepoint >> 6) & 0x3F))
		buf[2] = u8(0x80 | (codepoint & 0x3F)); n = 3
	case:
		buf[0] = u8(0xF0 | (codepoint >> 18)); buf[1] = u8(0x80 | ((codepoint >> 12) & 0x3F))
		buf[2] = u8(
			0x80 | ((codepoint >> 6) & 0x3F),
		); buf[3] = u8(0x80 | (codepoint & 0x3F)); n = 4
	}
	buf[n] = 0
	return measure_text_with(system, cstring(&buf[0]), size)
}

rune_width_frame :: proc(frame: ^Ui_Frame, value: rune, size: i32) -> i32 {
	assert(size > 0, "rune_width_frame: invalid size")
	return rune_width_with(ui_frame_text(frame), value, size)
}

draw_codepoint_with :: proc(
	system: ^Text_System,
	codepoint: rune,
	x, y: i32,
	size: i32,
	color: Color,
) {
	assert(system != nil)
}

draw_codepoint_frame :: proc(
	frame: ^Ui_Frame,
	codepoint: rune,
	x, y: i32,
	size: i32,
	color: Color,
) {
	assert(size > 0, "draw_codepoint_frame: invalid size")
	font := Font_Id(0)
	if text_backend_valid(frame.runtime.text_backend) do font = text_backend_font(frame.runtime.text_backend, size)
	draw_codepoint_command(frame, codepoint, x, y, size, color, font)
}

// LIB-CANDIDATE: imports only core:*.
package ui

import "core:strings"


UI_TELEMETRY_ENABLED :: #config(INGOT_UI_TELEMETRY, false)

FONT_DATA := #load("../assets/fonts/JetBrainsMono-Regular.ttf")

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
	measure_cache_hits:      u64,
	measure_cache_misses:    u64,
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

measure_cache_stats_with :: proc(system: ^Text_System) -> (entries: int, evictions: int) {
	assert(system != nil)
	return len(system.measure_cache), system.measure_cache_evictions
}

measure_cache_telemetry_with :: proc(system: ^Text_System) -> (hits, misses: u64) {
	assert(system != nil, "measure_cache_telemetry_with: nil system")
	return system.measure_cache_hits, system.measure_cache_misses
}

measure_cache_telemetry_reset_with :: proc(system: ^Text_System) {
	assert(system != nil, "measure_cache_telemetry_reset_with: nil system")
	system.measure_cache_hits = 0
	system.measure_cache_misses = 0
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
	if system.font_loaded do delete(system.font_codepoints)
	clear_measure_cache_with(system)
	clear_wrap_cache_with(system)
	system^ = {}
}

draw_text_with :: proc(system: ^Text_System, text: cstring, x, y, size: i32, color: Color) {
	assert(system != nil)
}

@(private)
frame_font_for_size :: proc(frame: ^Ui_Frame, size: i32) -> Font_Id {
	assert(frame != nil, "frame_font_for_size: nil frame")
	assert(size > 0, "frame_font_for_size: invalid size")
	if size == frame.font_memo_size do return frame.font_memo_id
	font := Font_Id(0)
	if text_backend_valid(frame.runtime.text_backend) {
		font = text_backend_font(frame.runtime.text_backend, size)
		frame.font_memo_size = size
		frame.font_memo_id = font
	}
	return font
}

draw_text_frame :: proc(frame: ^Ui_Frame, text: cstring, x, y, size: i32, color: Color) {
	assert(frame != nil, "draw_text_frame: nil frame")
	assert(size > 0, "draw_text_frame: invalid size")
	font := frame_font_for_size(frame, size)
	assert(
		frame.output == nil || font != 0,
		"draw_text_frame: paint output requires a text backend",
	)
	draw_cstring_command(frame, text, x, y, size, color, font)
}

// draw_text_string_frame is draw_text_frame for string labels: it skips the
// cstring clone the cstring entry point would otherwise force on callers.
draw_text_string_frame :: proc(frame: ^Ui_Frame, text: string, x, y, size: i32, color: Color) {
	assert(frame != nil, "draw_text_string_frame: nil frame")
	assert(size > 0, "draw_text_string_frame: invalid size")
	font := frame_font_for_size(frame, size)
	assert(
		frame.output == nil || font != 0,
		"draw_text_string_frame: paint output requires a text backend",
	)
	draw_text_command(frame, text, x, y, size, color, font)
}

MEASURE_CACHE_MAX :: 8192
MEASURE_CACHE_MAX_KEY_LEN :: 256

// Refresh an entry's LRU stamp only after it ages by this much, so cache
// hits are read-only in the common case instead of a map write per measure.
MEASURE_CACHE_STAMP_SLACK :: 1024

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
		when UI_TELEMETRY_ENABLED do system.measure_cache_hits += 1
		if system.measure_stamp - entry.stamp > MEASURE_CACHE_STAMP_SLACK {
			system.measure_stamp += 1
			entry.stamp = system.measure_stamp
			system.measure_cache[key] = entry
		}
		return entry.width
	}
	when UI_TELEMETRY_ENABLED do system.measure_cache_misses += 1
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
	assert(frame != nil, "measure_text_frame: nil frame")
	assert(size > 0, "measure_text_frame: invalid size")
	if text_backend_valid(frame.runtime.text_backend) {
		font := frame_font_for_size(frame, size)
		measurement := text_backend_measure(
			frame.runtime.text_backend,
			font,
			string(text),
			f32(size),
			0,
		)
		return i32(measurement.x + 0.5)
	}
	return measure_text_with(ui_frame_text(frame), text, size)
}

// measure_text_string_frame is measure_text_frame for string labels: the
// backend path measures the string directly with no cstring clone.
measure_text_string_frame :: proc(frame: ^Ui_Frame, text: string, size: i32) -> i32 {
	assert(frame != nil, "measure_text_string_frame: nil frame")
	assert(size > 0, "measure_text_string_frame: invalid size")
	if text_backend_valid(frame.runtime.text_backend) {
		font := frame_font_for_size(frame, size)
		measurement := text_backend_measure(frame.runtime.text_backend, font, text, f32(size), 0)
		return i32(measurement.x + 0.5)
	}
	text_c := strings.clone_to_cstring(text, context.temp_allocator)
	return measure_text_with(ui_frame_text(frame), text_c, size)
}

rune_utf8_encode :: proc(value: rune, buf: ^[5]u8) -> int {
	assert(buf != nil, "rune_utf8_encode: nil buffer")
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
	assert(n > 0 && n < len(buf), "rune_utf8_encode: invalid encoded rune")
	return n
}

rune_width_with :: proc(system: ^Text_System, value: rune, size: i32) -> i32 {
	assert(system != nil)
	buf: [5]u8
	rune_utf8_encode(value, &buf)
	return measure_text_with(system, cstring(&buf[0]), size)
}

rune_width_frame :: proc(frame: ^Ui_Frame, value: rune, size: i32) -> i32 {
	assert(frame != nil && frame.open, "rune_width_frame: invalid frame")
	assert(size > 0, "rune_width_frame: invalid size")
	buf: [5]u8
	rune_utf8_encode(value, &buf)
	return measure_text_frame(frame, cstring(&buf[0]), size)
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
	assert(frame != nil, "draw_codepoint_frame: nil frame")
	assert(size > 0, "draw_codepoint_frame: invalid size")
	font := frame_font_for_size(frame, size)
	assert(
		frame.output == nil || font != 0,
		"draw_codepoint_frame: paint output requires a text backend",
	)
	draw_codepoint_command(frame, codepoint, x, y, size, color, font)
}

draw_target_codepoint_frame :: proc(
	frame: ^Ui_Frame,
	codepoint: rune,
	x, y: i32,
	size: i32,
	color: Color,
) {
	assert(frame != nil, "draw_target_codepoint_frame: nil frame")
	assert(size > 0, "draw_target_codepoint_frame: invalid size")
	font := frame_font_for_size(frame, size)
	assert(font != 0, "draw_target_codepoint_frame: text backend required")
	draw_target_codepoint_command(frame, codepoint, x, y, size, color, font)
}

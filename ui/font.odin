// LIB-CANDIDATE: imports only core:*.
package ui

import "core:math"
import "core:strings"


UI_TELEMETRY_ENABLED :: #config(INGOT_UI_TELEMETRY, false)

FONT_DATA := #load("../assets/fonts/JetBrainsMono-Regular.ttf")

MEASURE_CACHE_MAX :: 8192
MEASURE_CACHE_MAX_KEY_LEN :: 1024
MEASURE_L0_CAPACITY :: 8
MEASURE_L0_MAX_KEY_LEN :: 64
ADVANCE_SLOT_CAPACITY :: 8
ADVANCE_ASCII_FIRST :: 0x20
ADVANCE_ASCII_COUNT :: 95
ADVANCE_CACHE_MAX :: 4096

Measure_Key :: struct {
	text:  string,
	size:  i32,
	font:  Font_Id,
	epoch: u64,
}

Measure_Entry :: struct {
	width: i32,
	stamp: u64,
}

Measure_L0_Entry :: struct {
	text:     [MEASURE_L0_MAX_KEY_LEN]u8,
	text_len: int,
	size:     i32,
	font:     Font_Id,
	epoch:    u64,
	width:    i32,
	valid:    bool,
}

// Advance_Slot caches per-rune advances for one (font, size, epoch) so the
// wrap/truncate hot paths never issue a backend measure per rune. ASCII
// (0x20-0x7E) lives in a fixed array; everything else falls back to the
// shared advance_cache map.
Advance_Slot :: struct {
	ascii:       [ADVANCE_ASCII_COUNT]i32,
	ascii_valid: [ADVANCE_ASCII_COUNT]bool,
	size:        i32,
	font:        Font_Id,
	epoch:       u64,
	valid:       bool,
}

Advance_Key :: struct {
	value: rune,
	size:  i32,
	font:  Font_Id,
	epoch: u64,
}

Text_System :: struct {
	font_loaded:                   bool,
	font_dpi:                      f32,
	font_codepoints:               []rune,
	measure_l0:                    [MEASURE_L0_CAPACITY]Measure_L0_Entry,
	measure_l0_next:               int,
	advance_slots:                 [ADVANCE_SLOT_CAPACITY]Advance_Slot,
	advance_slot_next:             int,
	advance_cache:                 map[Advance_Key]i32,
	measure_cache:                 map[Measure_Key]Measure_Entry,
	measure_cache_evictions:       int,
	measure_cache_hits:            u64,
	measure_cache_misses:          u64,
	measure_cache_policy_bypasses: u64,
	backend_measure_cache_enabled: bool,
	measure_stamp:                 u64,
	measure_backend:               proc(text: cstring, size: i32) -> i32,
	wrap_cache:                    map[Wrap_Key]Wrap_Entry,
	wrap_frame_cache:              map[Wrap_Frame_Key]Wrap_Entry,
	wrap_cache_evictions:          int,
	wrap_stamp:                    u64,
}

text_system_init :: proc(system: ^Text_System) {
	assert(system != nil)
	assert(!system.font_loaded)
	system.measure_l0 = {}
	system.measure_l0_next = 0
	system.backend_measure_cache_enabled = true
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

measure_cache_telemetry_with :: proc(system: ^Text_System) -> (hits, misses, bypasses: u64) {
	assert(system != nil, "measure_cache_telemetry_with: nil system")
	return system.measure_cache_hits,
		system.measure_cache_misses,
		system.measure_cache_policy_bypasses
}

measure_cache_telemetry_reset_with :: proc(system: ^Text_System) {
	assert(system != nil, "measure_cache_telemetry_reset_with: nil system")
	system.measure_cache_hits = 0
	system.measure_cache_misses = 0
	system.measure_cache_policy_bypasses = 0
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

@(private = "file")
measure_l0_get :: proc(system: ^Text_System, key: Measure_Key) -> (i32, bool) {
	assert(system != nil, "measure L0 get: nil system")
	if len(key.text) > MEASURE_L0_MAX_KEY_LEN do return 0, false
	for index in 0 ..< MEASURE_L0_CAPACITY {
		entry := &system.measure_l0[index]
		if entry.valid &&
		   entry.text_len == len(key.text) &&
		   entry.size == key.size &&
		   entry.font == key.font &&
		   entry.epoch == key.epoch &&
		   string(entry.text[:entry.text_len]) == key.text {
			return entry.width, true
		}
	}
	return 0, false
}

@(private = "file")
measure_l0_put :: proc(system: ^Text_System, key: Measure_Key, width: i32) {
	assert(system != nil, "measure L0 put: nil system")
	assert(
		system.measure_l0_next >= 0 && system.measure_l0_next < MEASURE_L0_CAPACITY,
		"measure L0 put: invalid replacement cursor",
	)
	if len(key.text) > MEASURE_L0_MAX_KEY_LEN do return
	entry := &system.measure_l0[system.measure_l0_next]
	entry^ = {
		text_len = len(key.text),
		size     = key.size,
		font     = key.font,
		epoch    = key.epoch,
		width    = width,
		valid    = true,
	}
	copy(entry.text[:entry.text_len], transmute([]u8)key.text)
	system.measure_l0_next += 1
	if system.measure_l0_next == MEASURE_L0_CAPACITY do system.measure_l0_next = 0
}

clear_measure_cache_with :: proc(system: ^Text_System) {
	assert(system != nil)
	system.measure_l0 = {}
	system.measure_l0_next = 0
	system.advance_slots = {}
	system.advance_slot_next = 0
	delete(system.advance_cache)
	system.advance_cache = nil
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
	assert(frame.runtime != nil, "frame_font_for_size: nil runtime")
	epoch := frame.runtime.font_epoch
	if size == frame.font_memo_size && epoch == frame.font_memo_epoch {
		return frame.font_memo_id
	}
	font := Font_Id(0)
	if text_backend_valid(frame.runtime.text_backend) {
		font = text_backend_font(frame.runtime.text_backend, size)
		frame.font_memo_size = size
		frame.font_memo_id = font
		frame.font_memo_epoch = epoch
	}
	return font
}

text_metrics_valid :: proc(metrics: Text_Metrics) -> bool {
	values := [4]f32{metrics.ascent, metrics.descent, metrics.line_gap, metrics.line_advance}
	for value in values {
		if math.is_nan(value) || math.is_inf(value, 0) do return false
	}
	return(
		metrics.ascent > 0 &&
		metrics.descent >= 0 &&
		metrics.line_gap >= 0 &&
		metrics.line_advance > 0 \
	)
}

text_metrics_frame :: proc(
	frame: ^Ui_Frame,
	font: Font_Id,
	font_size: f32,
) -> (
	Text_Metrics,
	bool,
) {
	assert(frame != nil && frame.runtime != nil, "text_metrics_frame: invalid frame")
	assert(font_size > 0, "text_metrics_frame: invalid size")
	backend := frame.runtime.text_backend
	if font == 0 || !text_backend_has_metrics(backend) do return {}, false
	metrics, ok := text_backend_metrics(backend, font, font_size)
	if !ok || !text_metrics_valid(metrics) do return {}, false
	return metrics, true
}

text_metrics_for_size_frame :: proc(frame: ^Ui_Frame, font_size: i32) -> (Text_Metrics, bool) {
	assert(frame != nil && frame.runtime != nil, "text metrics for size: invalid frame")
	assert(font_size > 0, "text metrics for size: invalid size")
	font := frame_font_for_size(frame, font_size)
	return text_metrics_frame(frame, font, f32(font_size))
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

// draw_text_string is the layer-friendly string draw: it resolves the backend
// font when one exists and falls back to Font_Id(0) otherwise, so headless
// tests can paint text without a text backend.
draw_text_string :: proc(frame: ^Ui_Frame, text: string, x, y, size: i32, color: Color) {
	assert(frame != nil, "draw_text_string: nil frame")
	assert(size > 0, "draw_text_string: invalid size")
	font := frame_font_for_size(frame, size)
	draw_text_command(frame, text, x, y, size, color, font)
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

// Refresh an entry's LRU stamp only after it ages by this much, so cache
// hits are read-only in the common case instead of a map write per measure.
MEASURE_CACHE_STAMP_SLACK :: 1024

// measure_cache_drop_all is the measure cache's eviction policy: when the
// cache fills, drop every entry. This is O(1) amortized per miss — the
// visible working set repopulates within a frame — unlike the previous
// evict-oldest linear scan, which cost O(MEASURE_CACHE_MAX) on every miss
// once a long chat pushed the working set past capacity.
@(private)
measure_cache_drop_all :: proc(system: ^Text_System) {
	assert(system != nil)
	assert(len(system.measure_cache) > 0)
	for key in system.measure_cache {
		delete(key.text)
	}
	clear(&system.measure_cache)
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
		if len(system.measure_cache) >= MEASURE_CACHE_MAX do measure_cache_drop_all(system)
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
		return measure_text_backend_cached(frame, string(text), size, font)
	}
	return measure_text_with(ui_frame_text(frame), text, size)
}

@(private = "file")
measure_text_backend_cached :: proc(
	frame: ^Ui_Frame,
	text: string,
	size: i32,
	font: Font_Id,
) -> i32 {
	assert(frame != nil && frame.runtime != nil, "measure backend cache: invalid frame")
	assert(size > 0 && font != 0, "measure backend cache: invalid font")
	system := &frame.runtime.text
	if !system.backend_measure_cache_enabled {
		when UI_TELEMETRY_ENABLED do system.measure_cache_policy_bypasses += 1
		measurement := text_backend_measure(frame.runtime.text_backend, font, text, f32(size), 0)
		return i32(measurement.x + 0.5)
	}
	key := Measure_Key {
		text  = text,
		size  = size,
		font  = font,
		epoch = frame.runtime.font_epoch,
	}
	if width, ok := measure_l0_get(system, key); ok {
		when UI_TELEMETRY_ENABLED do system.measure_cache_hits += 1
		return width
	}
	if entry, ok := system.measure_cache[key]; ok {
		when UI_TELEMETRY_ENABLED do system.measure_cache_hits += 1
		measure_l0_put(system, key, entry.width)
		return entry.width
	}
	when UI_TELEMETRY_ENABLED do system.measure_cache_misses += 1
	measurement := text_backend_measure(frame.runtime.text_backend, font, text, f32(size), 0)
	width := i32(measurement.x + 0.5)
	if len(text) <= MEASURE_CACHE_MAX_KEY_LEN {
		if len(system.measure_cache) >= MEASURE_CACHE_MAX do measure_cache_drop_all(system)
		system.measure_stamp += 1
		owned := Measure_Key {
			text  = strings.clone(text),
			size  = size,
			font  = font,
			epoch = frame.runtime.font_epoch,
		}
		system.measure_cache[owned] = {
			width = width,
			stamp = system.measure_stamp,
		}
		measure_l0_put(system, key, width)
	}
	return width
}

// measure_text_string_frame is measure_text_frame for string labels: the
// backend path measures the string directly with no cstring clone.
measure_text_string_frame :: proc(frame: ^Ui_Frame, text: string, size: i32) -> i32 {
	assert(frame != nil, "measure_text_string_frame: nil frame")
	assert(size > 0, "measure_text_string_frame: invalid size")
	if text_backend_valid(frame.runtime.text_backend) {
		font := frame_font_for_size(frame, size)
		return measure_text_backend_cached(frame, text, size, font)
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
	if text_backend_valid(frame.runtime.text_backend) {
		font := frame_font_for_size(frame, size)
		return rune_advance_backend_cached(frame, value, size, font)
	}
	buf: [5]u8
	rune_utf8_encode(value, &buf)
	return measure_text_frame(frame, cstring(&buf[0]), size)
}

@(private = "file")
advance_slot_for :: proc(
	system: ^Text_System,
	size: i32,
	font: Font_Id,
	epoch: u64,
) -> ^Advance_Slot {
	assert(system != nil, "advance slot: nil system")
	for index in 0 ..< ADVANCE_SLOT_CAPACITY {
		slot := &system.advance_slots[index]
		if slot.valid && slot.size == size && slot.font == font && slot.epoch == epoch {
			return slot
		}
	}
	assert(
		system.advance_slot_next >= 0 && system.advance_slot_next < ADVANCE_SLOT_CAPACITY,
		"advance slot: invalid replacement cursor",
	)
	slot := &system.advance_slots[system.advance_slot_next]
	system.advance_slot_next += 1
	if system.advance_slot_next == ADVANCE_SLOT_CAPACITY do system.advance_slot_next = 0
	slot^ = {
		size  = size,
		font  = font,
		epoch = epoch,
		valid = true,
	}
	return slot
}

@(private = "file")
rune_advance_measure_backend :: proc(
	frame: ^Ui_Frame,
	value: rune,
	size: i32,
	font: Font_Id,
) -> i32 {
	assert(frame != nil && frame.runtime != nil, "rune advance measure: invalid frame")
	buf: [5]u8
	n := rune_utf8_encode(value, &buf)
	measurement := text_backend_measure(
		frame.runtime.text_backend,
		font,
		string(buf[:n]),
		f32(size),
		0,
	)
	return i32(measurement.x + 0.5)
}

@(private = "file")
rune_advance_backend_cached :: proc(
	frame: ^Ui_Frame,
	value: rune,
	size: i32,
	font: Font_Id,
) -> i32 {
	assert(frame != nil && frame.runtime != nil, "rune advance cache: invalid frame")
	assert(size > 0 && font != 0, "rune advance cache: invalid font")
	system := &frame.runtime.text
	epoch := frame.runtime.font_epoch
	if value >= ADVANCE_ASCII_FIRST && value < ADVANCE_ASCII_FIRST + ADVANCE_ASCII_COUNT {
		slot := advance_slot_for(system, size, font, epoch)
		index := int(value) - ADVANCE_ASCII_FIRST
		if !slot.ascii_valid[index] {
			slot.ascii[index] = rune_advance_measure_backend(frame, value, size, font)
			slot.ascii_valid[index] = true
		}
		return slot.ascii[index]
	}
	key := Advance_Key {
		value = value,
		size  = size,
		font  = font,
		epoch = epoch,
	}
	if width, ok := system.advance_cache[key]; ok do return width
	width := rune_advance_measure_backend(frame, value, size, font)
	// Generational eviction: dropping the whole map is O(1) amortized and the
	// working set repopulates within a frame, unlike a per-miss linear scan.
	if len(system.advance_cache) >= ADVANCE_CACHE_MAX do clear(&system.advance_cache)
	system.advance_cache[key] = width
	return width
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
	backend := frame.runtime.text_backend
	if backend.has_glyph != nil && !backend.has_glyph(backend.data, font, codepoint) {
		frame.unsupported_glyphs += 1
		return
	}
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

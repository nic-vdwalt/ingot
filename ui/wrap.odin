// LIB-CANDIDATE: imports only core:*.
package ui

import "core:strings"
import "core:unicode/utf8"

Wrap_Line :: struct {
	start: int,
	end:   int,
}

Wrap_Key :: struct {
	text:  string,
	width: i32,
	size:  i32,
}

Wrap_Entry :: struct {
	lines: []Wrap_Line,
	stamp: u64,
}

WRAP_CACHE_MAX :: 4096

clear_wrap_cache_with :: proc(system: ^Text_System) {
	assert(system != nil)
	for key, entry in system.wrap_cache {
		delete(key.text)
		delete(entry.lines)
	}
	delete(system.wrap_cache)
	system.wrap_cache = nil
	system.wrap_stamp = 0
}

fnv1a64 :: proc(s: string) -> u64 {
	h: u64 = 0xcbf29ce484222325
	for i := 0; i < len(s); i += 1 {
		h = (h ~ u64(s[i])) * 0x100000001b3
	}
	return h
}

@(private)
wrap_evict_oldest :: proc(system: ^Text_System) {
	assert(system != nil)
	assert(len(system.wrap_cache) > 0)
	oldest: Wrap_Key
	oldest_stamp := max(u64)
	for key, entry in system.wrap_cache {
		if entry.stamp < oldest_stamp {
			oldest = key
			oldest_stamp = entry.stamp
		}
	}
	entry := system.wrap_cache[oldest]
	delete_key(&system.wrap_cache, oldest)
	delete(oldest.text)
	delete(entry.lines)
	system.wrap_cache_evictions += 1
}

wrap_text_with :: proc(
	system: ^Text_System,
	text: string,
	max_width: i32,
	font_size: i32,
) -> []Wrap_Line {
	assert(system != nil)
	assert(max_width >= 0 && font_size > 0)
	key := Wrap_Key {
		text  = text,
		width = max_width,
		size  = font_size,
	}
	if entry, ok := system.wrap_cache[key]; ok {
		system.wrap_stamp += 1
		entry.stamp = system.wrap_stamp
		system.wrap_cache[key] = entry
		return entry.lines
	}
	lines := wrap_compute_with(system, text, max_width, font_size)
	if len(system.wrap_cache) >= WRAP_CACHE_MAX do wrap_evict_oldest(system)
	owned_lines := make([]Wrap_Line, len(lines))
	copy(owned_lines, lines)
	system.wrap_stamp += 1
	owned_key := Wrap_Key {
		text  = strings.clone(text),
		width = max_width,
		size  = font_size,
	}
	system.wrap_cache[owned_key] = Wrap_Entry {
		lines = owned_lines,
		stamp = system.wrap_stamp,
	}
	return owned_lines
}

wrap_text_frame :: proc(
	frame: ^Ui_Frame,
	text: string,
	max_width: i32,
	font_size: i32,
) -> []Wrap_Line {
	assert(frame != nil && frame.open, "wrap_text_frame: invalid frame")
	assert(max_width >= 0 && font_size > 0, "wrap_text_frame: invalid dimensions")
	return wrap_compute_frame(frame, text, max_width, font_size)
}

@(private)
wrap_compute_with :: proc(
	system: ^Text_System,
	text: string,
	max_width: i32,
	font_size: i32,
	allocator := context.temp_allocator,
) -> []Wrap_Line {
	assert(system != nil)
	assert(max_width >= 0 && font_size > 0)
	lines := make([dynamic]Wrap_Line, context.temp_allocator)
	if len(text) == 0 {
		append(&lines, Wrap_Line{0, 0})
		return lines[:]
	}
	line_start := 0
	last_space := -1
	line_width: i32
	width_at_space: i32
	i := 0
	for i < len(text) {
		value := text[i]
		if value == '\n' {
			append(&lines, Wrap_Line{line_start, i})
			line_start = i + 1
			last_space = -1
			line_width = 0
			i += 1
			continue
		}
		next := i + 1
		for next < len(text) && (text[next] & 0xC0) == 0x80 do next += 1
		decoded, _ := utf8.decode_rune(text[i:next])
		advance := rune_width_with(system, decoded, font_size) + 1
		if value == ' ' {
			last_space = i
			width_at_space = line_width + advance
		}
		if line_width + advance > max_width && i > line_start {
			if last_space > line_start {
				append(&lines, Wrap_Line{line_start, last_space})
				line_start = last_space + 1
				line_width -= width_at_space
			} else {
				append(&lines, Wrap_Line{line_start, i})
				line_start = i
				line_width = 0
			}
			last_space = -1
			continue
		}
		line_width += advance
		i = next
	}
	append(&lines, Wrap_Line{line_start, len(text)})
	return lines[:]
}

wrap_compute_frame :: proc(
	frame: ^Ui_Frame,
	text: string,
	max_width: i32,
	font_size: i32,
) -> []Wrap_Line {
	assert(frame != nil && frame.open, "wrap_compute_frame: invalid frame")
	assert(max_width >= 0 && font_size > 0, "wrap_compute_frame: invalid dimensions")
	lines := make([dynamic]Wrap_Line, context.temp_allocator)
	if len(text) == 0 {
		append(&lines, Wrap_Line{0, 0})
		return lines[:]
	}
	line_start := 0
	last_space := -1
	line_width: i32
	width_at_space: i32
	i := 0
	for i < len(text) {
		value := text[i]
		if value == '\n' {
			append(&lines, Wrap_Line{line_start, i})
			line_start = i + 1
			last_space = -1
			line_width = 0
			i += 1
			continue
		}
		next := i + 1
		for next < len(text) && (text[next] & 0xC0) == 0x80 do next += 1
		decoded, _ := utf8.decode_rune(text[i:next])
		advance := rune_width_frame(frame, decoded, font_size) + 1
		if value == ' ' {
			last_space = i
			width_at_space = line_width + advance
		}
		if line_width + advance > max_width && i > line_start {
			if last_space > line_start {
				append(&lines, Wrap_Line{line_start, last_space})
				line_start = last_space + 1
				line_width -= width_at_space
			} else {
				append(&lines, Wrap_Line{line_start, i})
				line_start = i
				line_width = 0
			}
			last_space = -1
			continue
		}
		line_width += advance
		i = next
	}
	append(&lines, Wrap_Line{line_start, len(text)})
	return lines[:]
}

wrapped_height_px_with :: proc(
	system: ^Text_System,
	text: string,
	max_width, font_size, line_height: i32,
) -> i32 {
	assert(system != nil)
	assert(line_height > 0)
	return i32(len(wrap_text_with(system, text, max_width, font_size))) * line_height
}

wrapped_height_px_frame :: proc(
	frame: ^Ui_Frame,
	text: string,
	max_width, font_size, line_height: i32,
) -> i32 {
	assert(frame != nil && frame.open, "wrapped_height_px_frame: invalid frame")
	assert(max_width >= 0 && font_size > 0, "wrapped_height_px_frame: invalid dimensions")
	assert(line_height > 0, "wrapped_height_px_frame: invalid line height")
	return i32(len(wrap_text_frame(frame, text, max_width, font_size))) * line_height
}

wrapped_max_line_width_with :: proc(
	system: ^Text_System,
	text: string,
	max_width, font_size: i32,
) -> i32 {
	assert(system != nil)
	width: i32
	for line in wrap_text_with(system, text, max_width, font_size) {
		if line.end <= line.start do continue
		value := strings.clone_to_cstring(text[line.start:line.end], context.temp_allocator)
		line_width := measure_text_with(system, value, font_size)
		if line_width > width do width = line_width
	}
	return min(width, max_width)
}

wrapped_max_line_width_frame :: proc(
	frame: ^Ui_Frame,
	text: string,
	max_width, font_size: i32,
) -> i32 {
	assert(frame != nil && frame.open, "wrapped_max_line_width_frame: invalid frame")
	assert(max_width >= 0 && font_size > 0, "wrapped_max_line_width_frame: invalid dimensions")
	width: i32
	for line in wrap_text_frame(frame, text, max_width, font_size) {
		if line.end <= line.start do continue
		value := strings.clone_to_cstring(text[line.start:line.end], context.temp_allocator)
		line_width := measure_text_frame(frame, value, font_size)
		if line_width > width do width = line_width
	}
	return min(width, max_width)
}

wrapped_max_line_width_md_with :: proc(
	system: ^Text_System,
	text: string,
	max_width, font_size: i32,
) -> i32 {
	assert(system != nil)
	if !strings.contains(text, "**") &&
	   strings.index_byte(text, PILL_OPEN) < 0 &&
	   strings.index_byte(text, '`') < 0 {
		return wrapped_max_line_width_with(system, text, max_width, font_size)
	}
	spans := parse_inline_spans_with(text)
	display := spans_display_string_with(spans)
	return wrapped_max_line_width_with(system, display, max_width, font_size)
}

wrapped_max_line_width_md_frame :: proc(
	frame: ^Ui_Frame,
	text: string,
	max_width, font_size: i32,
) -> i32 {
	assert(frame != nil && frame.open, "wrapped_max_line_width_md_frame: invalid frame")
	assert(max_width >= 0 && font_size > 0, "wrapped_max_line_width_md_frame: invalid dimensions")
	if !strings.contains(text, "**") &&
	   strings.index_byte(text, PILL_OPEN) < 0 &&
	   strings.index_byte(text, '`') < 0 {
		return wrapped_max_line_width_frame(frame, text, max_width, font_size)
	}
	spans := frame_view_items(frame, parse_inline_spans(frame, text))
	display := frame_string_value(frame, spans_display_string(frame, spans))
	return wrapped_max_line_width_frame(frame, display, max_width, font_size)
}

wrapped_last_line_start_with :: proc(
	system: ^Text_System,
	text: string,
	max_width, font_size: i32,
) -> int {
	assert(system != nil)
	lines := wrap_text_with(system, text, max_width, font_size)
	if len(lines) == 0 do return 0
	return lines[len(lines) - 1].start
}

wrapped_last_line_start_frame :: proc(
	frame: ^Ui_Frame,
	text: string,
	max_width, font_size: i32,
) -> int {
	assert(frame != nil && frame.open, "wrapped_last_line_start_frame: invalid frame")
	assert(max_width >= 0 && font_size > 0, "wrapped_last_line_start_frame: invalid dimensions")
	return wrapped_last_line_start_with(ui_frame_text(frame), text, max_width, font_size)
}

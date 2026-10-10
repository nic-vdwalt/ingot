package ui

import "core:strings"
import "core:unicode/utf8"

// Hit-test wrapped text. Returns byte offset into text at (mouse_x, mouse_y), or -1 if miss.
// Must mirror draw_text_wrapped wrapping logic exactly.
hit_test_wrapped_frame :: proc(
	frame: ^Ui_Frame,
	x, y, max_width: i32,
	text: string,
	mouse_x, mouse_y, font_size: i32,
) -> int {
	assert(frame != nil && frame.open, "hit_test_wrapped_frame: invalid frame")
	assert(max_width >= 0 && font_size > 0, "hit_test_wrapped_frame: invalid dimensions")
	if len(text) == 0 do return -1
	lines := wrap_text_frame(frame, text, max_width, font_size)
	row := clamp(int((mouse_y - y) / ui_frame_metrics(frame).LINE_HEIGHT), 0, len(lines) - 1)
	line := text[lines[row].start:lines[row].end]
	col := caret_pixel_to_col_frame(frame, line, mouse_x - x, font_size)
	return lines[row].start + caret_col_to_byte(line, col)
}

text_selection_rect :: proc(frame: ^Ui_Frame, x, y, width, font_size, line_height: i32) -> Rect {
	assert(frame != nil && frame.open, "text selection: invalid frame")
	assert(width > 0 && font_size > 0 && line_height > 0, "text selection: invalid dimensions")
	font_metrics, metrics_ok := text_metrics_for_size_frame(frame, font_size)
	metrics := caret_metrics_or_fallback(
		font_metrics,
		metrics_ok,
		f32(font_size),
		f32(line_height),
	)
	return caret_rect({f32(x), f32(y)}, f32(x), metrics, f32(width))
}

// Draw a single line with optional selection highlight behind it.
// Uses measured substrings for pixel-accurate highlight positioning.
draw_line_with_selection_frame :: proc(
	frame: ^Ui_Frame,
	x, y: i32,
	line: string,
	font_size, line_height: i32,
	color: Color,
	line_byte_start, sel_start, sel_end: int,
) {
	assert(frame != nil, "draw_line_with_selection_frame: nil frame")
	line_byte_end := line_byte_start + len(line)
	hl_start := max(sel_start, line_byte_start)
	hl_end := min(sel_end, line_byte_end)
	if hl_start < hl_end {
		local_start := hl_start - line_byte_start
		local_end := hl_end - line_byte_start
		prefix_c := strings.clone_to_cstring(line[:local_start], context.temp_allocator)
		hl_x := x + measure_text_frame(frame, prefix_c, font_size)
		span_c := strings.clone_to_cstring(line[local_start:local_end], context.temp_allocator)
		hl_w := max(measure_text_frame(frame, span_c, font_size), 1)
		highlight := text_selection_rect(frame, hl_x, y, hl_w, font_size, line_height)
		draw_rectangle_rec(frame, highlight, ui_frame_theme(frame).bg_selection)
	}
	line_c := strings.clone_to_cstring(line, context.temp_allocator)
	draw_text_frame(frame, line_c, x, y, font_size, color)
}

// Vertical viewport culling belongs to the frame so nested or interleaved
// renderers cannot leak a process-global clipping band into each other.
set_text_cull_band_frame :: proc(frame: ^Ui_Frame, top, bottom: i32) {
	assert(frame != nil && frame.open, "set_text_cull_band_frame: invalid frame")
	assert(top <= bottom, "set_text_cull_band_frame: inverted band")
	frame.text_cull_top = top
	frame.text_cull_bottom = bottom
}

clear_text_cull_band_frame :: proc(frame: ^Ui_Frame) {
	assert(frame != nil && frame.open, "clear_text_cull_band_frame: invalid frame")
	frame.text_cull_top = min(i32)
	frame.text_cull_bottom = max(i32)
}

line_culled_frame :: proc(frame: ^Ui_Frame, y, line_height: i32) -> bool {
	assert(frame != nil && frame.open, "line_culled_frame: invalid frame")
	assert(line_height > 0, "line_culled_frame: invalid line height")
	return y + line_height < frame.text_cull_top || y > frame.text_cull_bottom
}

// rect_culled_frame reports whether a widget rect lies entirely outside the
// current vertical cull band, so leaf painters can skip emitting geometry the
// scissor would discard anyway. The rect analogue of line_culled_frame.
//
// Culling is vertical only: panes scroll on Y, and a band is far cheaper to
// maintain than a full rect intersection. A degenerate (zero-height) rect is
// never culled - callers already special-case those, and treating them as
// culled here would silently change existing behavior.
//
// This decides *painting* only. Interaction, focus registration, and semantics
// must still run for culled widgets or a scrolled-away control would lose its
// identity, tab order, and accessibility record.
rect_culled_frame :: proc(frame: ^Ui_Frame, rect: Rect_I32) -> bool {
	assert(frame != nil && frame.open, "rect_culled_frame: invalid frame")
	assert(frame.text_cull_top <= frame.text_cull_bottom, "rect_culled_frame: inverted band")
	if rect.h <= 0 do return false
	return rect.y + rect.h < frame.text_cull_top || rect.y > frame.text_cull_bottom
}

draw_text_wrapped_frame :: proc(
	frame: ^Ui_Frame,
	x, y, max_width: i32,
	text: string,
	color: Color,
	font_size, line_height: i32,
	sel_start: int = -1,
	sel_end: int = -1,
	draw: bool = true,
) -> i32 {
	assert(frame != nil && frame.open, "draw_text_wrapped_frame: invalid frame")
	assert(
		max_width >= 0 && font_size > 0 && line_height > 0,
		"draw_text_wrapped_frame: invalid metrics",
	)
	if len(text) == 0 do return 0
	current_y := y
	for line in wrap_text_frame(frame, text, max_width, font_size) {
		if !line_culled_frame(frame, current_y, line_height) && draw {
			value := text[line.start:line.end]
			if sel_start >= 0 && sel_end > sel_start {
				draw_line_with_selection_frame(
					frame,
					x,
					current_y,
					value,
					font_size,
					line_height,
					color,
					line.start,
					sel_start,
					sel_end,
				)
			} else {
				draw_text_string_frame(frame, value, x, current_y, font_size, color)
			}
		}
		current_y += line_height
	}
	return current_y - y
}

// Draw a single line of text, cutting it with an ellipsis if it would exceed
// max_width. Used for labels/paths in modals that must never overflow.
draw_text_truncated_frame :: proc(
	frame: ^Ui_Frame,
	text: string,
	x, y, max_width, font_size: i32,
	color: Color,
) {
	assert(frame != nil, "draw_text_truncated_frame: nil frame")
	assert(max_width >= 0 && font_size > 0, "draw_text_truncated_frame: invalid metrics")
	if len(text) == 0 do return
	out := truncate_to_width_frame(frame, text, max_width, font_size)
	draw_text_string_frame(frame, out, x, y, font_size, color)
}

// Draw a rounded "pill" badge with text. Returns the pill's full width so the
// caller can advance horizontally. Background and foreground are caller-chosen.
draw_pill :: proc(frame: ^Ui_Frame, text: string, x, y, font_size: i32, fg, bg: Color) -> i32 {
	assert(frame != nil, "draw_pill: nil frame")
	tw := measure_text_string_frame(frame, text, font_size)
	pad_h: i32 = 6
	pill_w := tw + pad_h * 2
	pill_h := frame_text_size(frame, font_size) + 4
	rect := Rectangle{f32(x), f32(y), f32(pill_w), f32(pill_h)}
	draw_rounded_fill(frame, rect, .Pill, bg)
	draw_text_string_frame(frame, text, x + pad_h, y + 2, font_size, fg)
	return pill_w
}

// Truncate_Side selects which side of the text an ellipsis replaces.
Truncate_Side :: enum u8 {
	Tail, // trailing ellipsis - keep the head visible
	Head, // leading ellipsis - keep the tail visible
}

// Text_Measure names which measurement path a truncation must use.
//
// Why it exists: measure_text_frame prefers the runtime's text backend when one
// is installed (ui_gfx installs one), while measure_text_with only ever asks the
// legacy Text_System. Auto-sizing widgets measure through the frame, so a
// truncator that measured through the system disagreed with the width the
// layout had just reserved and clipped labels that fit exactly - visible as
// "Enable wi…" on a row with room to spare. Both sides now resolve through one
// procedure, so the sizing and clipping decisions cannot diverge.
Text_Measure :: struct {
	frame:  ^Ui_Frame,
	system: ^Text_System,
}

@(private)
text_measure_width :: proc(measure: Text_Measure, text: cstring, font_size: i32) -> i32 {
	assert(measure.frame != nil || measure.system != nil, "text_measure_width: no measurer")
	assert(font_size > 0, "text_measure_width: non-positive font size")
	if measure.frame != nil do return measure_text_frame(measure.frame, text, font_size)
	return measure_text_with(measure.system, text, font_size)
}

// text_measure_width_string measures a string without forcing a cstring clone
// on the frame path; the legacy Text_System path still clones because its
// measure entry point takes a cstring.
@(private)
text_measure_width_string :: proc(measure: Text_Measure, text: string, font_size: i32) -> i32 {
	assert(measure.frame != nil || measure.system != nil, "text_measure_width_string: no measurer")
	assert(font_size > 0, "text_measure_width_string: non-positive font size")
	if measure.frame != nil do return measure_text_string_frame(measure.frame, text, font_size)
	text_c := strings.clone_to_cstring(text, context.temp_allocator)
	return measure_text_with(measure.system, text_c, font_size)
}

// text_measure_rune_width resolves a single rune advance through the same
// measurement path the truncator verifies with, using the frame's cached
// per-rune advances when a backend is installed.
@(private)
text_measure_rune_width :: proc(measure: Text_Measure, value: rune, font_size: i32) -> i32 {
	assert(measure.frame != nil || measure.system != nil, "text_measure_rune_width: no measurer")
	if measure.frame != nil do return rune_width_frame(measure.frame, value, font_size)
	return rune_width_with(measure.system, value, font_size)
}

// Return text truncated with an ellipsis on `side` so it fits max_width.
// The returned string is allocated in the temp allocator (or is the input
// unchanged when it already fits).
@(private)
truncate_to_width_dir_measure :: proc(
	measure: Text_Measure,
	text: string,
	max_width, font_size: i32,
	side: Truncate_Side,
) -> string {
	assert(max_width >= 0, "truncate_to_width_dir: negative width")
	assert(font_size > 0, "truncate_to_width_dir: non-positive font size")
	if len(text) == 0 do return text
	if text_measure_width_string(measure, text, font_size) <= max_width {
		return text
	}
	avail := max_width - text_measure_width_string(measure, "…", font_size)
	if side == .Tail {
		// Accumulate cached rune advances forward — O(n) — then verify with a
		// full measure and shrink by whole runes if advances under-estimated.
		// The old loop re-measured the whole prefix per rune step: O(n²).
		end := 0
		acc: i32 = 0
		for end < len(text) {
			r, n := utf8.decode_rune_in_string(text[end:])
			advance := text_measure_rune_width(measure, r, font_size)
			if acc + advance > avail do break
			acc += advance
			end += n
		}
		for end > 0 {
			candidate := strings.concatenate({text[:end], "…"}, context.temp_allocator)
			if text_measure_width_string(measure, candidate, font_size) <= max_width {
				return candidate
			}
			_, n := utf8.decode_last_rune_in_string(text[:end])
			end -= n
		}
		return strings.clone("…", context.temp_allocator)
	}
	// Accumulate cached rune advances backward — O(n) — then verify with a
	// full measure and shrink by whole runes if advances under-estimated.
	start := len(text)
	acc: i32 = 0
	for start > 0 {
		r, n := utf8.decode_last_rune_in_string(text[:start])
		advance := text_measure_rune_width(measure, r, font_size)
		if acc + advance > avail do break
		acc += advance
		start -= n
	}
	for start < len(text) {
		candidate := strings.concatenate({"…", text[start:]}, context.temp_allocator)
		if text_measure_width_string(measure, candidate, font_size) <= max_width {
			return candidate
		}
		_, n := utf8.decode_rune_in_string(text[start:])
		start += n
	}
	return strings.clone("…", context.temp_allocator)
}

truncate_to_width_dir_with :: proc(
	system: ^Text_System,
	text: string,
	max_width, font_size: i32,
	side: Truncate_Side,
) -> string {
	assert(system != nil, "truncate_to_width_dir_with: nil system")
	assert(font_size > 0, "truncate_to_width_dir_with: non-positive font size")
	return truncate_to_width_dir_measure({system = system}, text, max_width, font_size, side)
}

truncate_to_width_dir_frame :: proc(
	frame: ^Ui_Frame,
	text: string,
	max_width, font_size: i32,
	side: Truncate_Side,
) -> string {
	assert(frame != nil, "truncate_to_width_dir_frame: nil frame")
	assert(font_size > 0, "truncate_to_width_dir_frame: non-positive font size")
	return truncate_to_width_dir_measure({frame = frame}, text, max_width, font_size, side)
}

truncate_to_width_frame :: proc(
	frame: ^Ui_Frame,
	text: string,
	max_width, font_size: i32,
) -> string {
	return truncate_to_width_dir_frame(frame, text, max_width, font_size, .Tail)
}

// Return text truncated with a trailing ellipsis so it fits within max_width.
truncate_to_width_left_frame :: proc(
	frame: ^Ui_Frame,
	text: string,
	max_width, font_size: i32,
) -> string {
	return truncate_to_width_dir_frame(frame, text, max_width, font_size, .Head)
}

// Return a path truncated in the MIDDLE so the first directory segment and the
// final segment (filename) stay visible when it would otherwise overflow
// max_width, e.g. "alloy/…/widgets.odin". A trailing '/' on directory entries
// is preserved. Allocated in the temp allocator.
truncate_path_middle_frame :: proc(
	frame: ^Ui_Frame,
	path: string,
	max_width, font_size: i32,
) -> string {
	assert(frame != nil, "truncate_path_middle_frame: nil frame")
	assert(font_size > 0, "truncate_path_middle_frame: non-positive font size")
	measure := Text_Measure {
		frame = frame,
	}
	if len(path) == 0 do return path
	full_c := strings.clone_to_cstring(path, context.temp_allocator)
	if text_measure_width(measure, full_c, font_size) <= max_width {
		return path
	}

	// Peel an optional trailing separator (directory entries end with '/').
	body := path
	trailing := ""
	if body[len(body) - 1] == '/' || body[len(body) - 1] == '\\' {
		trailing = body[len(body) - 1:]
		body = body[:len(body) - 1]
	}

	// Paths use '/' or '\' (Windows); reuse the path's own separator style.
	last_sep := max(strings.last_index_byte(body, '/'), strings.last_index_byte(body, '\\'))
	if last_sep < 0 {
		// No directory component - keep the tail of the bare name visible.
		return truncate_to_width_dir_frame(frame, path, max_width, font_size, .Head)
	}
	sep := body[last_sep:last_sep + 1]
	last_seg := body[last_sep + 1:]
	first_sep := strings.index_byte(body, '/')
	if bs := strings.index_byte(body, '\\'); bs >= 0 && (first_sep < 0 || bs < first_sep) {
		first_sep = bs
	}
	first_seg := body[:first_sep]

	// Candidate 1: first/…/last (+ optional trailing separator).
	cand := strings.concatenate(
		{first_seg, sep, "…", sep, last_seg, trailing},
		context.temp_allocator,
	)
	cand_c := strings.clone_to_cstring(cand, context.temp_allocator)
	if text_measure_width(measure, cand_c, font_size) <= max_width {
		return cand
	}

	// Candidate 2: …/last - drop the leading segment.
	cand2 := strings.concatenate({"…", sep, last_seg, trailing}, context.temp_allocator)
	cand2_c := strings.clone_to_cstring(cand2, context.temp_allocator)
	if text_measure_width(measure, cand2_c, font_size) <= max_width {
		return cand2
	}

	// Candidate 3: even …/last is too wide - left-truncate the whole thing so
	// the filename's tail/extension stays visible.
	return truncate_to_width_dir_frame(frame, path, max_width, font_size, .Head)
}

// Bytes >= 0x80 (UTF-8 lead/continuation bytes) count as word bytes so
// multi-byte runes never split a word; boundaries stay at ASCII non-word
// bytes. Same byte-wise trick as spell_word_byte.

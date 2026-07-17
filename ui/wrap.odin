// LIB-CANDIDATE: imports only core:* and vendor:raylib.
package ui

import "core:strings"
import "core:unicode/utf8"

// One visual (wrapped) line: byte range [start, end) into the source string.
// `end` excludes the trailing space/newline that triggered the break.
Wrap_Line :: struct {
	start: int,
	end:   int,
}

// --- Global wrap memo --------------------------------------------------------
// Repeated frames re-wrap identical (text, width, size). Cache the resulting
// visual lines keyed by a cheap content hash so the steady state is O(1).
@(private = "file")
Wrap_Key :: struct {
	hash:  u64,
	len:   int,
	width: i32,
	size:  i32,
}

@(private = "file") wrap_cache: map[Wrap_Key][]Wrap_Line
@(private = "file") WRAP_CACHE_MAX :: 4096

// clear_wrap_cache flushes all cached wrapped-line layouts. Call when the UI
// scale changes so lines wrapped at the old font size/spacing are dropped.
clear_wrap_cache :: proc() {
	for k in wrap_cache {
		delete(wrap_cache[k])
	}
	clear(&wrap_cache)
}

// FNV-1a 64-bit hash of a byte string. Shared with other UI memos.
fnv1a64 :: proc(s: string) -> u64 {
	h: u64 = 0xcbf29ce484222325
	for i := 0; i < len(s); i += 1 {
		h = (h ~ u64(s[i])) * 0x100000001b3
	}
	return h
}

// Pixel-accurate greedy word wrap. Returns cached visual lines for repeated
// (text, width, size). On a miss it computes via wrap_compute and stores a
// heap-owned copy. The returned slice is read-only and owned by the cache.
wrap_text :: proc(text: string, max_width: i32, font_size: i32 = FONT_SIZE) -> []Wrap_Line {
	key := Wrap_Key{hash = fnv1a64(text), len = len(text), width = max_width, size = font_size}
	if cached, ok := wrap_cache[key]; ok {
		return cached
	}
	lines := wrap_compute(text, max_width, font_size)
	if len(wrap_cache) >= WRAP_CACHE_MAX {
		// Evict ~half the entries instead of flushing everything — a full
		// flush causes a hitch frame where all visible text re-wraps at once.
		doomed := make([dynamic]Wrap_Key, 0, WRAP_CACHE_MAX / 2, context.temp_allocator)
		for k in wrap_cache {
			if len(doomed) >= WRAP_CACHE_MAX / 2 do break
			append(&doomed, k)
		}
		for k in doomed {
			delete(wrap_cache[k])
			delete_key(&wrap_cache, k)
		}
	}
	owned := make([]Wrap_Line, len(lines))
	copy(owned, lines)
	wrap_cache[key] = owned
	return owned
}

// wrap_compute does the actual greedy word-wrap. Width is accumulated
// additively from per-rune widths (rune_width is cache-backed and bounded).
@(private = "file")
wrap_compute :: proc(text: string, max_width: i32, font_size: i32 = FONT_SIZE) -> []Wrap_Line {
	lines := make([dynamic]Wrap_Line, context.temp_allocator)
	if len(text) == 0 {
		append(&lines, Wrap_Line{0, 0})
		return lines[:]
	}

	line_start := 0
	last_space := -1
	line_w: i32 = 0     // accumulated pixel width of current line
	w_at_space: i32 = 0 // line_w up to and including last_space
	// Per-glyph spacing raylib adds between characters (mirrors draw_text /
	// measure_text). floor+1 guarantees at least 1 px of surplus at every DPI
	// scale, covering the truncation error from rune_width's i32 cast.
	sp := i32(f32(font_size) * 0.05) + 1
	i := 0
	for i < len(text) {
		c := text[i]
		if c == '\n' {
			append(&lines, Wrap_Line{line_start, i})
			line_start = i + 1
			last_space = -1
			line_w = 0
			i += 1
			continue
		}

		// Decode the current rune and its advance (glyph width + spacing).
		next := i + 1
		for next < len(text) && (text[next] & 0xC0) == 0x80 do next += 1
		r, _ := utf8.decode_rune(text[i:next])
		rw := rune_width(r, font_size) + sp
		if c == ' ' {
			last_space = i
			w_at_space = line_w + rw
		}

		if line_w + rw > max_width && next - line_start > 1 {
			if last_space > line_start {
				append(&lines, Wrap_Line{line_start, last_space})
				line_start = last_space + 1
				line_w -= w_at_space // carry the remainder after the space
			} else {
				// No space to break on: break before the current rune.
				append(&lines, Wrap_Line{line_start, i})
				line_start = i
				line_w = 0
			}
			last_space = -1
			continue // re-evaluate the current rune against the fresh line
		}
		line_w += rw
		i = next
	}

	append(&lines, Wrap_Line{line_start, len(text)})
	return lines[:]
}

// Total pixel height a wrapped block occupies.
wrapped_height_px :: proc(text: string, max_width: i32, font_size: i32 = FONT_SIZE) -> i32 {
	return i32(len(wrap_text(text, max_width, font_size))) * i32(LINE_HEIGHT)
}

// Widest visual (wrapped) line in pixels, capped at max_width.
wrapped_max_line_width :: proc(text: string, max_width: i32, font_size: i32 = FONT_SIZE) -> i32 {
	w: i32 = 0
	for ln in wrap_text(text, max_width, font_size) {
		if ln.end <= ln.start do continue
		slice := text[ln.start:ln.end]
		lc := strings.clone_to_cstring(slice, context.temp_allocator)
		lw := measure_text(lc, font_size)
		if lw > w do w = lw
	}
	if w > max_width do w = max_width
	return w
}

// Like wrapped_max_line_width but strips inline markdown markers (**bold**,
// `inline code`) so the measured width matches the display text.
wrapped_max_line_width_md :: proc(text: string, max_width: i32, font_size: i32 = FONT_SIZE) -> i32 {
	if !strings.contains(text, "**") && strings.index_byte(text, '`') < 0 {
		return wrapped_max_line_width(text, max_width, font_size)
	}
	spans := parse_inline_spans(text)
	display := spans_display_string(spans)
	return wrapped_max_line_width(display, max_width, font_size)
}

// Byte offset of the start of the last visual line (used to place the caret).
wrapped_last_line_start :: proc(text: string, max_width: i32, font_size: i32 = FONT_SIZE) -> int {
	lines := wrap_text(text, max_width, font_size)
	if len(lines) == 0 do return 0
	return lines[len(lines) - 1].start
}

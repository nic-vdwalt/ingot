// LIB-CANDIDATE: imports only core:* and ingot:gfx.
// Mention-pill geometry, encode/strip, and the workspace-path registry the
// markdown renderer consults for inline file pills. Extracted from alloy;
// decoupled from the app state package (uses ui.Mention_Span).
package ui

import "core:strings"
import rl "ingot:gfx"

// Sentinel bytes that bracket a mention path in stored message content. These
// are control chars that never appear in normal paths or prose.
PILL_OPEN :: '\x02'
PILL_CLOSE :: '\x03'

// --- Markdown file-pill context ---------------------------------------------

@(private = "file")
legacy_md_ws_files: []string

set_md_file_ctx :: proc(files: []string) {legacy_md_ws_files = files}
clear_md_file_ctx :: proc() {legacy_md_ws_files = nil}

workspace_has_path :: proc(rel: string) -> bool {
	if len(legacy_md_ws_files) == 0 || len(rel) == 0 || len(rel) > 256 do return false
	if strings.index_byte(rel, ' ') >= 0 || strings.index_byte(rel, '\n') >= 0 do return false
	directory := strings.concatenate({rel, "/"}, context.temp_allocator)
	for path in legacy_md_ws_files {
		if path == rel || path == directory do return true
	}
	return false
}

set_md_file_ctx_frame :: proc(frame: ^Ui_Frame, files: []string) {
	assert(frame != nil && frame.open, "set_md_file_ctx_frame: invalid frame")
	frame.markdown_ws_files = files
}

clear_md_file_ctx_frame :: proc(frame: ^Ui_Frame) {
	assert(frame != nil && frame.open, "clear_md_file_ctx_frame: invalid frame")
	frame.markdown_ws_files = nil
}

workspace_has_path_with :: proc(files: []string, rel: string) -> bool {
	if len(files) == 0 || len(rel) == 0 || len(rel) > 256 do return false
	if strings.index_byte(rel, ' ') >= 0 || strings.index_byte(rel, '\n') >= 0 do return false
	directory := strings.concatenate({rel, "/"}, context.temp_allocator)
	for path in files {
		if path == rel || path == directory do return true
	}
	return false
}

workspace_has_path_frame :: proc(frame: ^Ui_Frame, rel: string) -> bool {
	assert(frame != nil && frame.open, "workspace_has_path_frame: invalid frame")
	return workspace_has_path_with(frame.markdown_ws_files, rel)
}

// --- Range maintenance (composer) -------------------------------------------

// Shift pill ranges after inserting `n` bytes at byte offset `at`.
pills_shift_after_insert :: proc(pills: ^[dynamic]Mention_Span, at, n: int) {
	for &p in pills {
		if p.start >= at do p.start += n
		if p.end > at do p.end += n
	}
}

// Shift pill ranges after deleting bytes [at, at+n). Any pill that overlaps the
// deleted region is dropped (it stops being an atomic token).
pills_shift_after_delete :: proc(pills: ^[dynamic]Mention_Span, at, n: int) {
	keep := make([dynamic]Mention_Span, 0, len(pills), context.temp_allocator)
	for p in pills {
		if p.end <= at {
			append(&keep, p)
		} else if p.start >= at + n {
			append(&keep, Mention_Span{p.start - n, p.end - n})
		}
		// else: overlaps deletion -> drop.
	}
	clear(pills)
	for p in keep do append(pills, p)
}

// pills_drop_invalid removes pill ranges that fall outside [0, blen) after a
// whole-text rewrite (select-all replace / cut / clear / external reset).
pills_drop_invalid :: proc(pills: ^[dynamic]Mention_Span, blen: int) {
	assert(pills != nil, "pills_drop_invalid: nil pills")
	assert(blen >= 0, "pills_drop_invalid: negative buffer length")
	valid := make([dynamic]Mention_Span, 0, len(pills), context.temp_allocator)
	for p in pills {
		if p.start >= 0 && p.end <= blen && p.start < p.end {
			append(&valid, p)
		}
	}
	if len(valid) != len(pills) {
		clear(pills)
		for p in valid do append(pills, p)
	}
}

// Return the index of a pill whose END is exactly `pos`, or that strictly
// contains `pos` (start < pos < end). Used to decide atomic backspace.
pill_ending_at :: proc(pills: ^[dynamic]Mention_Span, pos: int) -> (int, bool) {
	for p, i in pills {
		if pos == p.end || (pos > p.start && pos < p.end) do return i, true
	}
	return -1, false
}

// Return the index of a pill whose START is exactly `pos`, or that strictly
// contains `pos`. Used for atomic forward-delete.
pill_starting_at :: proc(pills: ^[dynamic]Mention_Span, pos: int) -> (int, bool) {
	for p, i in pills {
		if pos == p.start || (pos > p.start && pos < p.end) do return i, true
	}
	return -1, false
}

// If `pos` falls strictly inside a pill, snap to the nearest edge.
pill_snap_caret :: proc(pills: ^[dynamic]Mention_Span, pos: int) -> int {
	for p in pills {
		if pos > p.start && pos < p.end {
			return p.start if pos - p.start < p.end - pos else p.end
		}
	}
	return pos
}

// If moving left landed strictly inside a pill, snap to its start.
pill_snap_left :: proc(pills: ^[dynamic]Mention_Span, pos: int) -> int {
	for p in pills {
		if pos > p.start && pos < p.end do return p.start
	}
	return pos
}

// If moving right landed strictly inside a pill, snap to its end.
pill_snap_right :: proc(pills: ^[dynamic]Mention_Span, pos: int) -> int {
	for p in pills {
		if pos > p.start && pos < p.end do return p.end
	}
	return pos
}

// Remove pill at index and return the [start,end) it occupied.
pill_remove :: proc(pills: ^[dynamic]Mention_Span, idx: int) -> (int, int) {
	p := pills[idx]
	ordered_remove(pills, idx)
	return p.start, p.end
}

// --- Marker encode / strip (message boundary) -------------------------------

// Encode plain `text` + pill ranges into content with PILL_OPEN/PILL_CLOSE
// sentinels around each pill. Ranges must be sorted ascending, non-overlapping.
// Returns a temp-allocated string.
encode_pills :: proc(text: string, pills: []Mention_Span) -> string {
	if len(pills) == 0 do return text
	sb := strings.builder_make(context.temp_allocator)
	prev := 0
	for p in pills {
		if p.start < prev || p.end > len(text) || p.start > p.end do continue
		strings.write_string(&sb, text[prev:p.start])
		strings.write_rune(&sb, PILL_OPEN)
		strings.write_string(&sb, text[p.start:p.end])
		strings.write_rune(&sb, PILL_CLOSE)
		prev = p.end
	}
	strings.write_string(&sb, text[prev:])
	return strings.to_string(sb)
}

// Remove all pill sentinels, returning clean text (for the wire + clipboard).
// Returns a temp-allocated string when stripping occurs, else the input.
strip_pill_markers :: proc(text: string) -> string {
	if strings.index_byte(text, PILL_OPEN) < 0 && strings.index_byte(text, PILL_CLOSE) < 0 {
		return text
	}
	sb := strings.builder_make(context.temp_allocator)
	for r in text {
		if r == PILL_OPEN || r == PILL_CLOSE do continue
		strings.write_rune(&sb, r)
	}
	return strings.to_string(sb)
}

// Draw a pill background behind a composer path run already laid out at
// [x, x+w). Mirrors the /history pill look (rounded chip).
draw_input_pill_bg_frame :: proc(frame: ^Ui_Frame, x, y, w: i32) {
	assert(frame != nil && frame.open, "draw_input_pill_bg_frame: invalid frame")
	metrics := ui_frame_metrics(frame)
	pad := ui_frame_sc(frame, 3)
	rect := rl.Rectangle {
		f32(x - pad),
		f32(y - ui_frame_sc(frame, 1)),
		f32(w + pad * 2),
		f32(metrics.FONT_SIZE_BODY + ui_frame_sc(frame, 4)),
	}
	rl.DrawRectangleRounded(rect, 0.5, 6, ui_frame_theme(frame).bg_chip)
}

draw_input_pill_bg :: proc(x, y, w: i32) {
	pad: i32 = 3
	rect := rl.Rectangle{f32(x - pad), f32(y - 1), f32(w + pad * 2), f32(FONT_SIZE + 4)}
	rl.DrawRectangleRounded(rect, 0.5, 6, theme.bg_chip)
}

// LIB-CANDIDATE: imports only core:*.
// Mention-pill geometry, encode/strip, and the workspace-path registry the
// markdown renderer consults for inline file pills. Extracted from alloy;
// decoupled from the app state package (uses ui.Mention_Span).
package ui

import "core:strings"


// Sentinel bytes that bracket a mention path in stored message content. These
// are control chars that never appear in normal paths or prose.
PILL_OPEN :: '\x02'
PILL_CLOSE :: '\x03'

Mention_Match_Score :: enum i32 {
	Name_Prefix   = 0,
	Name_Contains = 1,
	Path_Contains = 2,
	No_Match      = 3,
}

mention_basename :: proc(candidate: string) -> string {
	end := len(candidate)
	for end > 0 && (candidate[end - 1] == '/' || candidate[end - 1] == '\\') do end -= 1
	if end == 0 do return candidate[:0]
	start := end
	for start > 0 && candidate[start - 1] != '/' && candidate[start - 1] != '\\' do start -= 1
	return candidate[start:end]
}

mention_match_score :: proc(candidate, query: string) -> Mention_Match_Score {
	if len(query) == 0 do return .Name_Prefix
	candidate_lower := strings.to_lower(candidate, context.temp_allocator)
	query_lower := strings.to_lower(query, context.temp_allocator)
	name_lower := strings.to_lower(mention_basename(candidate), context.temp_allocator)
	if strings.has_prefix(name_lower, query_lower) do return .Name_Prefix
	if strings.contains(name_lower, query_lower) do return .Name_Contains
	if strings.contains(candidate_lower, query_lower) do return .Path_Contains
	return .No_Match
}

Tagged_Option_Config :: struct {
	rect:       Rect_I32,
	label:      string,
	icon:       string,
	trailing:   string,
	stable_id:  string,
	focus:      Focus_Opt,
	selected:   bool,
	icon_color: Color,
	tag_fg:     Color,
	tag_bg:     Color,
}

Tagged_Option_Result :: struct {
	pressable: Pressable_Result,
	text_x:    i32,
	text_w:    i32,
}

tagged_option_row :: proc(frame: ^Ui_Frame, config: Tagged_Option_Config) -> Tagged_Option_Result {
	assert(frame != nil && frame.open, "tagged_option_row: invalid frame")
	assert(config.label != "" && config.stable_id != "", "tagged_option_row: identity required")
	if ui_frame_drop_degenerate(frame, config.rect.w <= 0 || config.rect.h <= 0) do return {}
	style := ui_frame_theme(frame)
	metrics := ui_frame_metrics(frame)
	row := pressable(
		frame,
		{
			rect = config.rect,
			role = .Option,
			label = config.label,
			stable_id = config.stable_id,
			focus = config.focus,
			selected = config.selected,
		},
	)
	if config.selected {
		draw_rectangle(
			frame,
			config.rect.x,
			config.rect.y,
			config.rect.w,
			config.rect.h,
			style.bg_active,
		)
	}
	padding := metrics.PADDING
	text_x := config.rect.x + padding
	if len(config.icon) > 0 {
		icon_color := config.icon_color
		if icon_color == {} do icon_color = style.fg_secondary
		text(
			frame,
			config.icon,
			text_x,
			config.rect.y + (config.rect.h - metrics.FONT_SIZE_SMALL) / 2,
			.Small,
			.Secondary,
		)
		text_x += text_width(frame, config.icon, .Small) + ui_frame_sc(frame, 8)
	}
	trailing_width: i32 = 0
	if len(config.trailing) > 0 {
		trailing_width = text_width(frame, config.trailing, .Small) + ui_frame_sc(frame, 12)
		tag_fg := config.tag_fg
		if tag_fg == {} do tag_fg = style.fg_accent
		tag_bg := config.tag_bg
		if tag_bg == {} do tag_bg = style.bg_chip
		draw_pill(
			frame,
			config.trailing,
			config.rect.x + config.rect.w - padding - trailing_width,
			config.rect.y + (config.rect.h - metrics.FONT_SIZE_SMALL - ui_frame_sc(frame, 4)) / 2,
			metrics.FONT_SIZE_SMALL,
			tag_fg,
			tag_bg,
		)
	}
	text_width_available := config.rect.x + config.rect.w - padding - trailing_width - text_x
	return {pressable = row, text_x = text_x, text_w = max(text_width_available, 0)}
}

// --- Markdown file-pill context ---------------------------------------------

workspace_has_path_with :: proc(files: []string, rel: string) -> bool {
	if len(files) == 0 || len(rel) == 0 || len(rel) > 256 do return false
	if strings.index_byte(rel, ' ') >= 0 || strings.index_byte(rel, '\n') >= 0 do return false
	directory := strings.concatenate({rel, "/"}, context.temp_allocator)
	for path in files {
		if path == rel || path == directory do return true
	}
	return false
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
	assert(pills != nil)
	assert(at >= 0)
	assert(n >= 0)
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
	assert(pills != nil)
	assert(idx >= 0 && idx < len(pills))
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
		if p.start < 0 || p.start < prev || p.end > len(text) || p.start >= p.end do continue
		strings.write_string(&sb, text[prev:p.start])
		strings.write_rune(&sb, PILL_OPEN)
		strings.write_string(&sb, text[p.start:p.end])
		strings.write_rune(&sb, PILL_CLOSE)
		prev = p.end
	}
	strings.write_string(&sb, text[prev:])
	return strings.to_string(sb)
}

encode_pills_owned :: proc(
	text: string,
	pills: []Mention_Span,
	allocator := context.allocator,
) -> string {
	assert(allocator.procedure != nil)
	encoded := encode_pills(text, pills)
	result := strings.clone(encoded, allocator)
	assert(len(result) == len(encoded))
	return result
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
	rect := Rectangle {
		f32(x - pad),
		f32(y - ui_frame_sc(frame, 1)),
		f32(w + pad * 2),
		f32(metrics.FONT_SIZE_BODY + ui_frame_sc(frame, 4)),
	}
	draw_rectangle_rounded(frame, rect, 0.5, 6, ui_frame_theme(frame).bg_chip)
}

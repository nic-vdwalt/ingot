// LIB-CANDIDATE: imports only core:*.
// Widgets take plain data and return events; callers own all state.
// Merged from openalloy/alloy (superset input/undo/pill/split features)
// plus ingot-only generic widgets (spinner, panes, back_btn, etc.).
package ui

import "core:fmt"
import "core:math"
import "core:strings"
import "core:unicode/utf8"


begin_pane_scissor :: proc(frame: ^Ui_Frame, x, y, w, h: i32) {
	assert(frame != nil && frame.open, "begin_pane_scissor: invalid frame")
	assert(w > 0 && h > 0, "begin_pane_scissor: invalid rect")
	begin_scissor_mode(frame, x, y, w, h)
}

// draw_split_divider draws the vertical drag handle between the chat pane and
// the embedded nvim pane of a split Chat tab. x is the divider's left edge.
draw_split_divider :: proc(frame: ^Ui_Frame, x, screen_h: i32, hovered: bool) {
	assert(frame != nil, "draw_split_divider: nil frame")
	assert(screen_h > 0, "draw_split_divider: invalid screen height")
	style := ui_frame_theme(frame)
	metrics := ui_frame_metrics(frame)
	col := style.border_color
	if hovered do col = style.fg_accent
	draw_rectangle(
		frame,
		x,
		metrics.TAB_BAR_HEIGHT,
		metrics.SPLIT_DIVIDER_W,
		screen_h - metrics.TAB_BAR_HEIGHT,
		col,
	)
}

// draw_panel_header draws the unified header band used by side panels: a
// small label in the given accent color plus a hairline divider underneath.
// Returns the y just below the divider.
draw_panel_header :: proc(
	frame: ^Ui_Frame,
	x, y, w: i32,
	label: string,
	accent: Color = THEME_COLOR,
) -> i32 {
	assert(frame != nil, "draw_panel_header: nil frame")
	assert(w > 0, "draw_panel_header: invalid width")
	style := ui_frame_theme(frame)
	metrics := ui_frame_metrics(frame)
	accent := accent
	if accent == THEME_COLOR do accent = style.fg_label
	draw_text_string_frame(
		frame,
		label,
		x + metrics.PADDING,
		y + (metrics.PANEL_HEADER_H - metrics.FONT_SIZE_LABEL) / 2,
		metrics.FONT_SIZE_LABEL,
		accent,
	)
	draw_rectangle(frame, x, y + metrics.PANEL_HEADER_H - 1, w, 1, style.border_subtle)
	return y + metrics.PANEL_HEADER_H
}

// card_bg_at draws the unified card container: rounded background fill,
// hairline border, and optional left accent bar in a physical rectangle.
card_bg_at :: proc(
	frame: ^Ui_Frame,
	bounds: Rect_I32,
	bg: Color,
	accent: Color = THEME_COLOR,
	accent_w: i32 = 0,
) {
	assert(frame != nil, "card_bg_at: nil frame")
	rect := rect_f32(bounds)
	min_dim := min(rect.width, rect.height)
	if min_dim <= 0 do return
	draw_rounded_fill(frame, rect, .MD, bg)
	draw_rounded_border(frame, rect, .MD, .Hairline, ui_frame_theme(frame).border_subtle)
	if accent_w > 0 {
		inset := ui_frame_sc(frame, 2)
		draw_rectangle(
			frame,
			i32(rect.x),
			i32(rect.y) + inset,
			accent_w,
			i32(rect.height) - inset * 2,
			accent,
		)
	}
}

// draw_split_drop_hint previews where a tab dragged into the content area will
// land: it dims the content region and highlights the target half (left/right)
// with a divider preview down the middle.
draw_split_drop_hint :: proc(frame: ^Ui_Frame, screen_w, screen_h: i32, side_left: bool) {
	assert(frame != nil, "draw_split_drop_hint: nil frame")
	assert(screen_w > 0 && screen_h > 0, "draw_split_drop_hint: invalid screen size")
	style := ui_frame_theme(frame)
	top := ui_frame_metrics(frame).TAB_BAR_HEIGHT
	h := screen_h - top
	// The scrim and the target tint were a hardcoded black and an inline
	// re-alpha of fg_accent, while drop_zone_bg and drop_zone_border sat in
	// every palette unused. These are the roles that were meant for this.
	draw_rectangle(frame, 0, top, screen_w, h, color_tinted(style.modal_dim, .Medium))
	half := screen_w / 2
	hl := color_tinted(style.drop_zone_bg, .Medium)
	if side_left {
		draw_rectangle(frame, 0, top, half, h, hl)
	} else {
		draw_rectangle(frame, half, top, screen_w - half, h, hl)
	}
	draw_rectangle(
		frame,
		half - ui_frame_sc(frame, 1),
		top,
		ui_frame_sc(frame, 2),
		h,
		style.drop_zone_border,
	)
}

// input_is_selecting (selection queries) live in text_input.odin.

// mod_down reports whether a clipboard modifier (Cmd on macOS, Ctrl elsewhere)
// is currently held.
mod_down :: proc(frame: ^Ui_Frame) -> bool {
	assert(frame != nil, "mod_down: nil frame")
	return(
		is_key_down(frame, .LEFT_SUPER) ||
		is_key_down(frame, .RIGHT_SUPER) ||
		is_key_down(frame, .LEFT_CONTROL) ||
		is_key_down(frame, .RIGHT_CONTROL) \
	)
}

// Returns true if the mouse moved since the last frame.
// Used so keyboard arrow navigation in selection menus isn't overridden by a
// stationary cursor that happens to sit over an item. Mouse hover only changes
// the selection when the user is actively moving the mouse.
mouse_moved :: proc(frame: ^Ui_Frame) -> bool {
	delta := get_mouse_delta(frame)
	return delta.x != 0 || delta.y != 0
}

// get_wheel_move returns this frame's mouse-wheel delta scaled by a
// platform multiplier so scroll speed feels consistent across OSes.
// Windows mouse wheels produce 1.0 per notch while macOS trackpads
// deliver larger inertia-driven values; the multiplier compensates.
get_wheel_move :: proc(frame: ^Ui_Frame) -> f32 {
	wheel := get_mouse_wheel_move(frame)
	when ODIN_OS == .Windows {
		return wheel * 5.0
	} else {
		return wheel
	}
}

// Convert this frame's mouse-wheel delta into whole row steps, carrying
// fractional remainders in accum so small trackpad deltas are not lost.
// Resets the accumulator on direction reversal. Returns rows to scroll
// (positive = down the list).
wheel_row_steps :: proc(frame: ^Ui_Frame, accum: ^f32) -> int {
	return wheel_accum_steps(accum, get_wheel_move(frame))
}

// wheel_accum_steps is the pure core of wheel_row_steps: fold one frame's
// wheel delta into the accumulator and return whole row steps (positive =
// down the list). Split out so the carry/reversal logic is unit-testable
// without live mouse input.
wheel_accum_steps :: proc(accum: ^f32, wheel: f32) -> int {
	assert(accum != nil, "wheel_accum_steps: nil accumulator")
	if wheel == 0 do return 0
	if (accum^ > 0 && wheel < 0) || (accum^ < 0 && wheel > 0) {
		accum^ = 0
	}
	accum^ += wheel
	steps := int(accum^)
	accum^ -= f32(steps)
	// Why assert: the fractional remainder must stay below one full row or
	// steps were computed wrong.
	assert(accum^ > -1 && accum^ < 1, "wheel_accum_steps: remainder out of range")
	return -steps
}

// --- Caret helpers for multi-line text inputs -------------------------------
// All offsets are byte offsets into `s` on rune boundaries. Lines are split on
// '\n' only (the input does not soft-wrap).

// Byte offset of the start of the logical line containing `pos`.
caret_line_start :: proc(s: string, pos: int) -> int {
	assert(pos >= 0 && pos <= len(s))
	i := pos
	for i > 0 && s[i - 1] != '\n' do i -= 1
	return i
}

// Byte offset of the end of the logical line containing `pos` (the '\n' or len).
caret_line_end :: proc(s: string, pos: int) -> int {
	i := pos
	for i < len(s) && s[i] != '\n' do i += 1
	return i
}

// Convert a byte offset to (row, rune-column).
caret_row_col :: proc(s: string, pos: int) -> (row: int, col: int) {
	for i := 0; i < pos && i < len(s); {
		if s[i] == '\n' {
			row += 1
			col = 0
			i += 1
		} else {
			j := i + 1
			for j < len(s) && (s[j] & 0xC0) == 0x80 do j += 1
			col += 1
			i = j
		}
	}
	return
}

// Convert (row, rune-column) back to a byte offset, clamping to line length.
caret_from_row_col :: proc(s: string, row, col: int) -> int {
	line := 0
	i := 0
	for i < len(s) && line < row {
		if s[i] == '\n' do line += 1
		i += 1
	}
	c := 0
	for i < len(s) && s[i] != '\n' && c < col {
		j := i + 1
		for j < len(s) && (s[j] & 0xC0) == 0x80 do j += 1
		i = j
		c += 1
	}
	return i
}

// Number of logical lines (newline count + 1).
caret_line_count :: proc(s: string) -> int {
	n := 1
	for i := 0; i < len(s); i += 1 {
		if s[i] == '\n' do n += 1
	}
	return n
}

// Move one rune left from `pos`, returning the new byte offset.
caret_prev_rune :: proc(s: string, pos: int) -> int {
	assert(pos >= 0, "caret_prev_rune: negative offset")
	assert(pos <= len(s), "caret_prev_rune: offset past end")
	if pos <= 0 do return 0
	i := pos - 1
	for i > 0 && (s[i] & 0xC0) == 0x80 do i -= 1
	return i
}

// Move one rune right from `pos`, returning the new byte offset.
caret_next_rune :: proc(s: string, pos: int) -> int {
	assert(pos >= 0, "caret_next_rune: negative offset")
	assert(pos <= len(s), "caret_next_rune: offset past end")
	if pos >= len(s) do return len(s)
	i := pos + 1
	for i < len(s) && (s[i] & 0xC0) == 0x80 do i += 1
	return i
}

// Move one grapheme cluster right from `pos`, returning the new byte offset.
// Emoji ZWJ sequences and combining-mark pairs step as one unit, matching
// what the user perceives as a single character. Scans clusters from the
// line start so a mid-cluster caret still sees full left context (resuming
// segmentation mid-sequence would fabricate boundaries).
caret_next_grapheme :: proc(s: string, pos: int) -> int {
	assert(pos >= 0, "caret_next_grapheme: negative offset")
	assert(pos <= len(s), "caret_next_grapheme: offset past end")
	if pos >= len(s) do return len(s)
	p := caret_clamp(s, pos)
	if s[p] == '\n' do return p + 1 // on the newline: step onto the next line
	start := caret_line_start(s, p)
	end := caret_line_end(s, p)
	it := utf8.decode_grapheme_iterator_make(s[start:end])
	for _, g in utf8.decode_grapheme_iterate(&it) {
		if start + g.byte_index > p do return start + g.byte_index
	}
	return end // caret in the line's last cluster: next stop is the line end
}

// Move one grapheme cluster left from `pos`, returning the new byte offset.
// Scans clusters from the current line start: cluster boundaries never span
// '\n' (breaks occur around controls), so one line bounds the walk.
caret_prev_grapheme :: proc(s: string, pos: int) -> int {
	assert(pos >= 0, "caret_prev_grapheme: negative offset")
	assert(pos <= len(s), "caret_prev_grapheme: offset past end")
	if pos <= 0 do return 0
	p := caret_clamp(s, pos)
	if p == 0 do return 0
	start := caret_line_start(s, p)
	if p == start do return p - 1 // at a line start: step over the newline
	prev := start
	it := utf8.decode_grapheme_iterator_make(s[start:p])
	for _, g in utf8.decode_grapheme_iterate(&it) {
		if start + g.byte_index >= p do break
		prev = start + g.byte_index
	}
	return prev
}

// Word-jump left (skip trailing whitespace/newlines, then a run of non-space).
caret_word_left :: proc(s: string, pos: int) -> int {
	assert(pos >= 0 && pos <= len(s))
	i := pos
	for i > 0 && (s[i - 1] == ' ' || s[i - 1] == '\n') do i -= 1
	for i > 0 {
		c := s[i - 1]
		if c == ' ' || c == '\n' do break
		i -= 1
	}
	return i
}

// Word-jump right (skip leading whitespace/newlines, then a run of non-space).
caret_word_right :: proc(s: string, pos: int) -> int {
	i := pos
	for i < len(s) && (s[i] == ' ' || s[i] == '\n') do i += 1
	for i < len(s) {
		c := s[i]
		if c == ' ' || c == '\n' do break
		i += 1
	}
	return i
}

// Clamp `pos` into [0, len(s)] and snap down to the nearest rune boundary.
caret_clamp :: proc(s: string, pos: int) -> int {
	p := pos
	if p < 0 do p = 0
	if p > len(s) do p = len(s)
	for p > 0 && p < len(s) && (s[p] & 0xC0) == 0x80 do p -= 1
	// Why assert: every caller trusts the result as a safe slicing offset;
	// a mid-rune result would split a UTF-8 sequence on the next edit. p == 0
	// is exempt because malformed input may begin with a continuation byte.
	assert(p >= 0 && p <= len(s), "caret_clamp: result out of bounds")
	assert(p == 0 || p == len(s) || (s[p] & 0xC0) != 0x80, "caret_clamp: mid-rune result")
	return p
}

// Insert `text` at `pos`, returning the new caret position (pos + len(inserted)).
caret_insert :: proc(sb: ^strings.Builder, pos: int, text: string) -> int {
	assert(sb != nil, "caret_insert: nil sb")
	old := strings.to_string(sb^)
	insert := text
	before := old[:pos]
	after := old[pos:]
	if len(before) + len(insert) + len(after) > INPUT_MAX_LEN {
		room := INPUT_MAX_LEN - (len(before) + len(after))
		if room <= 0 do return pos
		r := room
		if r > len(insert) do r = len(insert)
		for r > 0 && r < len(insert) && (insert[r] & 0xC0) == 0x80 do r -= 1
		insert = insert[:r]
	}
	combined := strings.concatenate({before, insert, after}, context.temp_allocator)
	strings.builder_reset(sb)
	strings.write_string(sb, combined)
	return pos + len(insert)
}

// Byte offset within a single line for a given rune column.
caret_col_to_byte :: proc(line: string, col: int) -> int {
	i := 0
	c := 0
	for i < len(line) && c < col {
		j := i + 1
		for j < len(line) && (line[j] & 0xC0) == 0x80 do j += 1
		i = j
		c += 1
	}
	return i
}

@(private = "file")
caret_measure_with :: proc(data: rawptr, prefix: cstring, font_size: i32) -> i32 {
	assert(data != nil, "caret_measure_with: nil system")
	assert(font_size > 0, "caret_measure_with: invalid font size")
	return measure_text_with((^Text_System)(data), prefix, font_size)
}

@(private = "file")
caret_measure_frame :: proc(data: rawptr, prefix: cstring, font_size: i32) -> i32 {
	assert(data != nil, "caret_measure_frame: nil frame")
	assert(font_size > 0, "caret_measure_frame: invalid font size")
	return measure_text_frame((^Ui_Frame)(data), prefix, font_size)
}

caret_pixel_to_col_with :: proc(system: ^Text_System, line: string, px, font_size: i32) -> int {
	assert(system != nil, "caret_pixel_to_col_with: nil text system")
	assert(font_size > 0, "caret_pixel_to_col_with: invalid font size")
	return caret_pixel_to_col_search(system, caret_measure_with, line, px, font_size)
}

caret_pixel_to_col_frame :: proc(frame: ^Ui_Frame, line: string, px, font_size: i32) -> int {
	assert(frame != nil && frame.open, "caret_pixel_to_col_frame: invalid frame")
	assert(font_size > 0, "caret_pixel_to_col_frame: invalid font size")
	return caret_pixel_to_col_search(frame, caret_measure_frame, line, px, font_size)
}

// caret_pixel_to_col_search maps a pixel offset to the nearest rune column
// by binary-searching prefix widths (monotonic in prefix length). The old
// linear scan measured every prefix - O(n^2) work per call, re-run every
// frame of a mouse drag; the search does O(log n) prefix measures and
// returns the identical nearest-boundary column.
@(private = "file")
caret_pixel_to_col_search :: proc(
	measure_data: rawptr,
	measure: proc(data: rawptr, prefix: cstring, font_size: i32) -> i32,
	line: string,
	px, font_size: i32,
) -> int {
	assert(measure != nil, "caret_pixel_to_col_search: nil measure")
	assert(font_size > 0, "caret_pixel_to_col_search: invalid font size")
	if px <= 0 do return 0
	// Rune-start offsets plus the end-of-line sentinel: starts[k] is the byte
	// length of the k-rune prefix.
	starts := make([dynamic]int, context.temp_allocator)
	append(&starts, 0)
	for i := 0; i < len(line); {
		j := i + 1
		for j < len(line) && (line[j] & 0xC0) == 0x80 do j += 1
		append(&starts, j)
		i = j
	}
	count := len(starts) - 1
	if count == 0 do return 0
	full := strings.clone_to_cstring(line, context.temp_allocator)
	hi_width := measure(measure_data, full, font_size)
	if hi_width <= px do return count
	// Invariant: width(lo runes) <= px < width(hi runes); the gap halves
	// every iteration, so the loop is bounded by log2(count).
	lo, hi := 0, count
	lo_width: i32 = 0
	for hi - lo > 1 {
		mid := lo + (hi - lo) / 2
		prefix := strings.clone_to_cstring(line[:starts[mid]], context.temp_allocator)
		width := measure(measure_data, prefix, font_size)
		if width > px {
			hi, hi_width = mid, width
		} else {
			lo, lo_width = mid, width
		}
	}
	assert(lo_width <= px && px < hi_width, "caret_pixel_to_col_search: invariant broken")
	// Snap to whichever boundary of the straddling rune is nearer, exactly
	// as the linear scan did.
	if px - lo_width < hi_width - px do return lo
	return hi
}

// Delete the rune before `pos` (backspace). Returns the new caret position.
caret_delete_prev :: proc(sb: ^strings.Builder, pos: int) -> int {
	assert(sb != nil, "caret_delete_prev: nil sb")
	if pos <= 0 do return 0
	old := strings.to_string(sb^)
	start := caret_prev_rune(old, pos)
	combined := strings.concatenate({old[:start], old[pos:]}, context.temp_allocator)
	strings.builder_reset(sb)
	strings.write_string(sb, combined)
	return start
}

// Delete the rune at `pos` (forward delete). Returns `pos` unchanged.
caret_delete_next :: proc(sb: ^strings.Builder, pos: int) -> int {
	assert(sb != nil, "caret_delete_next: nil sb")
	old := strings.to_string(sb^)
	if pos >= len(old) do return pos
	end := caret_next_rune(old, pos)
	combined := strings.concatenate({old[:pos], old[end:]}, context.temp_allocator)
	strings.builder_reset(sb)
	strings.write_string(sb, combined)
	return pos
}


// --- Interactive vertical scrollbar ----------------------------------------

// Scrollbar_State is caller-owned drag state, so multiple scrollbars can be
// dragged independently (one per Pane, or standalone via scrollbar_ex).
Scrollbar_State :: struct {
	dragging: bool,
	grab_dy:  f32,
}

// Draw a draggable vertical scrollbar (track + thumb) and return the updated
// first-visible-row offset. total and visible are row counts; offset is the
// current first visible row. Supports thumb dragging and track-click jumps.
// Uses the shared module drag slot; prefer scrollbar_ex for per-instance state.
// scrollbar_ex is scrollbar with caller-owned drag state.
scrollbar_ex :: proc(
	frame: ^Ui_Frame,
	st: ^Scrollbar_State,
	x, y, w, h: i32,
	total, visible, offset: int,
) -> int {
	// Why assert: negative row counts mean the caller mixed up pixel and row
	// units; every later division would silently produce garbage offsets.
	assert(st != nil, "scrollbar_ex: nil state")
	assert(total >= 0 && visible >= 0, "scrollbar_ex: negative row counts")
	assert(w > 0, "scrollbar_ex: non-positive width")
	if total <= visible || h <= 0 {
		// Content shrank below the viewport mid-drag: drop the latch and
		// release the frame's arbitration slot in the same breath. The
		// generation check in interact_frame_begin would reclaim it on the
		// next frame anyway; doing it here avoids one frame of dead input.
		if st.dragging {
			st.dragging = false
			interact_forget(frame, &st.dragging)
		}
		return 0
	}
	max_off := total - visible
	off := clamp(offset, 0, max_off)

	style := ui_frame_theme(frame)
	draw_rectangle(frame, x, y, w, h, style.bg_secondary)
	thumb_h := max(ui_frame_sc(frame, 20), h * i32(visible) / i32(total))
	track_range := max(h - thumb_h, 1)
	thumb_y := y + i32(f32(track_range) * f32(off) / f32(max_off))

	mouse := get_mouse_position(frame)
	mouse = frame_to_local(frame, mouse)
	thumb_rect := Rectangle{f32(x), f32(thumb_y), f32(w), f32(thumb_h)}
	track_rect := Rectangle{f32(x), f32(y), f32(w), f32(h)}

	it := interact(frame, track_rect, &st.dragging)
	if it.pressed {
		if point_in_rect(mouse, thumb_rect) {
			st.grab_dy = mouse.y - f32(thumb_y)
		} else {
			// Jump: center the thumb on the click, then keep dragging.
			st.grab_dy = f32(thumb_h) / 2
		}
	}
	if it.held {
		t := (mouse.y - st.grab_dy - f32(y)) / f32(track_range)
		off = clamp(int(t * f32(max_off) + 0.5), 0, max_off)
	}

	// Recompute the thumb position after a drag update.
	thumb_y = y + i32(f32(track_range) * f32(off) / f32(max_off))
	thumb_hover :=
		it.hovered && point_in_rect(mouse, Rectangle{f32(x), f32(thumb_y), f32(w), f32(thumb_h)})
	col := style.border_color
	if st.dragging || thumb_hover do col = style.fg_accent
	draw_rectangle(frame, x, thumb_y, w, thumb_h, col)
	return off
}

// Button visual style variants.
Btn_Style :: enum {
	Primary, // Accent-colored bg, white text.
	Secondary, // Muted bg, brightens on hover, accent border on hover.
	Danger, // Red-tinted bg, light-red text.
	Ghost, // Nearly transparent, text-driven, accent color on hover.
}

// color_mix linearly blends a toward b by t (0..1) per channel, alpha
// included, so widgets can fade between two theme states over time.
color_mix :: proc(a, b: Color, t: f32) -> Color {
	assert(t >= 0 && t <= 1, "color_mix: t out of range")
	mix_u8 :: proc(x, y: u8, t: f32) -> u8 {
		return u8(clamp(f32(x) + (f32(y) - f32(x)) * t, 0, 255))
	}
	return Color {
		mix_u8(a.r, b.r, t),
		mix_u8(a.g, b.g, t),
		mix_u8(a.b, b.b, t),
		mix_u8(a.a, b.a, t),
	}
}

Button_State :: struct {
	hover: f32,
}

hover_anim_step :: proc(state: ^f32, hovered: bool, dt: f32) -> f32 {
	assert(state != nil, "hover_anim_step: nil state")
	target: f32 = 1 if hovered else 0
	eased(state, target, dt, 14.0)
	state^ = clamp(state^, 0, 1)
	return state^
}

hover_anim_frac :: proc(frame: ^Ui_Frame, state: ^Button_State, hovered: bool) -> f32 {
	assert(state != nil, "hover_anim_frac: nil state")
	if ui_frame_theme(frame).reduced_motion {
		state.hover = 1 if hovered else 0
		return state.hover
	}
	t := hover_anim_step(&state.hover, hovered, frame_input(frame).frame_time)
	target: f32 = 1 if hovered else 0
	if t != target do request_redraw(frame)
	assert(t >= 0 && t <= 1, "hover_anim_frac: fraction out of range")
	return t
}

// btn_palette returns the (rest, hovered) bg/fg/border colors for a style so
// btn can blend between them with the eased hover fraction.
@(private = "package")
btn_palette :: proc(theme: ^Theme, style: Btn_Style) -> (bg0, bg1, fg0, fg1, bd0, bd1: Color) {
	assert(theme != nil, "btn_palette: nil theme")
	switch style {
	case .Primary:
		return theme.button_bg,
			theme.button_hover,
			theme.button_text,
			theme.button_text,
			theme.border_color,
			theme.fg_accent
	case .Secondary:
		return theme.bg_active,
			theme.bg_hover,
			theme.fg_secondary,
			theme.fg_primary,
			theme.border_color,
			theme.fg_accent
	case .Danger:
		return theme.button_danger_bg,
			theme.button_danger_hover,
			theme.button_danger_fg,
			theme.button_danger_fg,
			Color{},
			theme.fg_error
	case .Ghost:
		return Color{}, theme.bg_hover, theme.fg_secondary, theme.fg_accent, Color{}, Color{}
	}
	return
}

// btn_gloss overlays a subtle top-half sheen on a button. The gradient quad
// is inset past the corner radius because scissor modes don't nest in gfx and
// a raw full-width quad would spill outside the rounded corners.
@(private = "file")
btn_gloss :: proc(frame: ^Ui_Frame, theme: ^Theme, rect: Rectangle) {
	assert(frame != nil && theme != nil, "btn_gloss: invalid argument")
	top := theme.button_primary_grad_top
	if top.a == 0 do return
	radius := radius_pixels(frame, .MD, min(rect.width, rect.height))
	inset := i32(radius) + 1
	gw := i32(rect.width) - inset * 2
	if gw <= 0 do return
	draw_rectangle_gradient_v(
		frame,
		i32(rect.x) + inset,
		i32(rect.y) + 1,
		gw,
		i32(rect.height / 2),
		top,
		theme.button_primary_grad_bottom,
	)
}

Button_Options :: struct {
	style:       Btn_Style,
	disabled:    bool,
	web_form_id: string,
}

Button_Spec :: struct {
	id:      Widget_Id,
	label:   string,
	options: Button_Options,
}

button_spec :: proc(
	u: ^Ui,
	id: Widget_Id,
	label: string,
	options: Button_Options = {},
) -> Button_Spec {
	assert(u != nil && u.open, "button_spec: frame not open")
	assert(id != WIDGET_ID_NONE && label != "", "button_spec: invalid identity or label")
	return {id, label, options}
}

button_spec_size :: proc(u: ^Ui, spec: Button_Spec) -> Intrinsic_Size {
	assert(u != nil && u.open && u.frame != nil, "button_spec_size: invalid UI")
	assert(spec.id != WIDGET_ID_NONE && spec.label != "", "button_spec_size: invalid spec")
	metrics := ui_frame_metrics(u.frame)
	width := button_fit_width(u.frame, spec.label, metrics.FONT_SIZE_LABEL)
	return intrinsic_leaf(width, metrics.ROW_H_MD)
}

button_spec_at :: proc(u: ^Ui, spec: Button_Spec, rect: Rect_I32) -> bool {
	assert(u != nil && u.open, "button_spec_at: frame not open")
	assert(spec.id != WIDGET_ID_NONE && spec.label != "", "button_spec_at: invalid spec")
	enabled := !spec.options.disabled
	fo := focus(u, spec.id) if enabled && slot_visible(rect) else Focus_Opt{}
	return button_at(
		u.frame,
		rect,
		spec.label,
		spec.options.style,
		enabled = enabled,
		web_form_id = spec.options.web_form_id,
		focus = fo,
		widget = spec.id,
	)
}

Button_At_Options :: struct {
	style:       Btn_Style,
	font_size:   i32,
	disabled:    bool,
	web_form_id: string,
	focus:       Focus_Opt,
	widget:      Widget_Id,
}

// Unified button. Returns true if clicked this frame. Hover eases in/out via
// hover_anim_frac (frame-rate independent); pressed state darkens instantly.
// Pass `focus` to make the button keyboard-operable: clicking acquires the
// slot, the ring draws while focused, and Space/Enter activates.
//
// Widget tiers - see docs/ui-state.md#widget-tiers:
//   button      facade: a ^Ui plus a Widget_Id, carving a bounded slot.
//   button_at   explicit: a ^Ui_Frame plus an application-owned Rect_I32.
@(private = "package")
button_id :: proc(
	u: ^Ui,
	id: Widget_Id,
	label: string,
	style: Btn_Style = .Secondary,
	enabled: bool = true,
	web_form_id: string = "",
) -> bool {
	assert(u != nil && u.open, "button: frame not open")
	assert(id != WIDGET_ID_NONE, "button: zero stable id")
	assert(label != "", "button: empty accessible label")
	spec := button_spec(
		u,
		id,
		label,
		{style = style, disabled = !enabled, web_form_id = web_form_id},
	)
	size := button_spec_size(u, spec)
	return button_spec_at(u, spec, slot_next_px(u, size.w, size.h))
}

@(private = "package")
button_string :: proc(
	u: ^Ui,
	key: string,
	label: string,
	style: Btn_Style = .Secondary,
	enabled: bool = true,
) -> bool {
	return button_id(u, id(u, key), label, style, enabled)
}

@(private = "package")
button_u64 :: proc(
	u: ^Ui,
	key: u64,
	label: string,
	style: Btn_Style = .Secondary,
	enabled: bool = true,
) -> bool {
	return button_id(u, id(u, key), label, style, enabled)
}

@(private = "package")
button_id_options :: proc(u: ^Ui, id: Widget_Id, label: string, options: Button_Options) -> bool {
	return button_id(u, id, label, options.style, !options.disabled, options.web_form_id)
}

@(private = "package")
button_string_options :: proc(u: ^Ui, key, label: string, options: Button_Options) -> bool {
	return button_id_options(u, id(u, key), label, options)
}

@(private = "package")
button_u64_options :: proc(u: ^Ui, key: u64, label: string, options: Button_Options) -> bool {
	return button_id_options(u, id(u, key), label, options)
}

button :: proc {
	button_id,
	button_string,
	button_u64,
	button_id_options,
	button_string_options,
	button_u64_options,
}

@(private = "file")
button_fit_width :: proc(frame: ^Ui_Frame, label: string, font_size: i32) -> i32 {
	assert(frame != nil && font_size > 0, "button_fit_width: invalid frame or size")
	assert(label != "", "button_fit_width: empty label")
	width :=
		measure_text_string_frame(frame, label, font_size) + ui_frame_metrics(frame).PADDING * 2
	assert(width > 0, "button_fit_width: invalid width")
	return width
}

// button_fit_w_frame returns the pixel width a rect-based button (button_at,
// icon_btn_at) needs to draw `label` without ellipsis truncation: the measured
// text plus the standard horizontal padding on both sides. Size caller-owned
// rects with it instead of hardcoding widths that silently truncate.
button_fit_w_frame :: proc(frame: ^Ui_Frame, label: string, font_size: i32 = 0) -> i32 {
	assert(frame != nil, "button_fit_w_frame: nil frame")
	assert(label != "", "button_fit_w_frame: empty label")
	metrics := ui_frame_metrics(frame)
	fs := font_size if font_size > 0 else metrics.FONT_SIZE_LABEL
	return button_fit_width(frame, label, fs)
}

// Fit a button label to the button box: truncate with an ellipsis when it is
// too wide, and return the drawn text plus its measured width for centring.
@(private = "file")
btn_label_fit :: proc(frame: ^Ui_Frame, label: string, w, font_size: i32) -> (string, i32) {
	assert(frame != nil, "btn_label_fit: nil frame")
	assert(font_size > 0, "btn_label_fit: non-positive font size")
	assert(label != "", "btn_label_fit: empty label")
	pad := ui_frame_metrics(frame).CONTROL_GAP
	avail := max(w - pad * 2, 0)
	width := measure_text_string_frame(frame, label, font_size)
	if width <= avail do return label, width
	fitted := truncate_to_width_frame(frame, label, avail, font_size)
	return fitted, measure_text_string_frame(frame, fitted, font_size)
}

// btn_sync_web_submit mirrors a button into the browser form overlay (web
// builds with an installed backend): the DOM submit button drives the
// browser's save-password and autofill flows. Returns true when the DOM form
// submitted this frame.
@(private = "file")
btn_sync_web_submit :: proc(
	frame: ^Ui_Frame,
	web_form_id, label: string,
	x, y, w, h: i32,
	style: Btn_Style,
	font_size: i32,
	enabled: bool,
) -> bool {
	assert(frame != nil, "btn_sync_web_submit: nil frame")
	if web_form_id == "" do return false
	backend := ui_frame_runtime(frame).web_form
	if backend.sync_submit_button == nil do return false
	return backend.sync_submit_button(
		backend.data,
		web_form_id,
		label,
		x,
		y,
		w,
		h,
		i32(style),
		font_size,
		enabled,
	)
}

button_at :: proc(
	frame: ^Ui_Frame,
	rect: Rect_I32,
	label: string,
	style: Btn_Style = .Secondary,
	font_size: i32 = 0,
	enabled: bool = true,
	web_form_id: string = "",
	focus: Focus_Opt = {},
	widget: Widget_Id = WIDGET_ID_NONE,
) -> bool {
	assert(frame != nil, "button_at: nil frame")
	// Why assert: a nameless control is invisible to assistive tech.
	assert(label != "", "button_at: empty accessible label")
	x, y, w, h := rect.x, rect.y, rect.w, rect.h
	metrics := ui_frame_metrics(frame)
	fs := font_size if font_size > 0 else metrics.FONT_SIZE_LABEL
	style_theme := ui_frame_theme(frame)
	rrect := rect_f32(rect)
	it := interact(frame, rrect)
	hovered := enabled && it.hovered
	clicked := enabled && it.clicked
	if enabled {
		focus_opt_click(frame, focus, x, y, w, h)
		clicked = clicked || focus_opt_activated(frame, focus, .Button, widget)
	}
	clicked =
		clicked || btn_sync_web_submit(frame, web_form_id, label, x, y, w, h, style, fs, enabled)
	if hovered do request_cursor(frame, .POINTING_HAND)

	// Painting is skipped for a button scrolled outside the enclosing pane;
	// interaction, focus, and semantics above and below still run, so a
	// culled button keeps its identity, tab order, and screen-reader record.
	// The scissor would discard this geometry at raster time anyway - the
	// saving is in never building, copying, and uploading it.
	if !rect_culled_frame(frame, rect) {
		t: f32 = 1 if hovered else 0
		bg0, bg1, fg0, fg1, bd0, bd1 := btn_palette(style_theme, style)
		bg := color_mix(bg0, bg1, t)
		fg := color_mix(fg0, fg1, t)
		border := color_mix(bd0, bd1, t)
		// Pressed feedback while the mouse button is held over the button.
		if hovered &&
		   is_mouse_button_down(frame, .LEFT) &&
		   (style == .Primary || style == .Secondary) {
			bg = style_theme.button_pressed
		}
		if !enabled {
			bg = style_theme.button_disabled_bg
			// fg_disabled, not fg_muted_dim. Two roles for one concept meant a
			// disabled button and a disabled menu item rendered in different
			// colors in the same frame; fg_muted_dim is now Ink.Muted only.
			fg = style_theme.fg_disabled
			border = {}
		}

		draw_rounded_fill(frame, rrect, .MD, bg)
		if style == .Primary && enabled do btn_gloss(frame, style_theme, rrect)
		draw_rounded_border(frame, rrect, .MD, .Hairline, border)
		if enabled && focus_opt_focused(focus) {
			draw_focus_ring(frame, x, y, w, h)
		}

		label_s, text_w := btn_label_fit(frame, label, w, fs)
		draw_text_string_frame(frame, label_s, x + (w - text_w) / 2, y + (h - fs) / 2, fs, fg)
	}

	sem: Sem_State
	if !enabled do sem += {.Disabled}
	semantic_push(frame, .Button, rect, label, sem, focus, widget = widget)
	return clicked && enabled
}

button_with_options_at :: proc(
	frame: ^Ui_Frame,
	rect: Rect_I32,
	label: string,
	options: Button_At_Options,
) -> bool {
	assert(frame != nil, "button_at: nil frame")
	return button_at(
		frame,
		rect,
		label,
		options.style,
		options.font_size,
		!options.disabled,
		options.web_form_id,
		options.focus,
		options.widget,
	)
}

// button_at_state is button_at plus caller-owned hover animation state.
button_at_state :: proc(
	frame: ^Ui_Frame,
	state: ^Button_State,
	rect: Rect_I32,
	label: string,
	style: Btn_Style = .Secondary,
	font_size: i32 = 0,
	enabled: bool = true,
	web_form_id: string = "",
	focus: Focus_Opt = {},
	widget: Widget_Id = WIDGET_ID_NONE,
) -> bool {
	assert(state != nil, "button_at_state: nil state")
	assert(label != "", "button_at_state: empty accessible label")
	x, y, w, h := rect.x, rect.y, rect.w, rect.h
	metrics := ui_frame_metrics(frame)
	fs := font_size if font_size > 0 else metrics.FONT_SIZE_LABEL
	style_theme := ui_frame_theme(frame)
	rrect := rect_f32(rect)
	it := interact(frame, rrect)
	hovered := enabled && it.hovered
	clicked := enabled && it.clicked
	if enabled {
		focus_opt_click(frame, focus, x, y, w, h)
		clicked = clicked || focus_opt_activated(frame, focus, .Button, widget)
	}
	clicked =
		clicked || btn_sync_web_submit(frame, web_form_id, label, x, y, w, h, style, fs, enabled)
	if hovered do request_cursor(frame, .POINTING_HAND)
	t := hover_anim_frac(frame, state, hovered) if enabled else 0
	bg0, bg1, fg0, fg1, bd0, bd1 := btn_palette(style_theme, style)
	bg := color_mix(bg0, bg1, t)
	fg := color_mix(fg0, fg1, t)
	border := color_mix(bd0, bd1, t)
	if hovered &&
	   is_mouse_button_down(frame, .LEFT) &&
	   (style == .Primary || style == .Secondary) {
		bg = style_theme.button_pressed
	}
	if !enabled {
		state.hover = 0
		bg = style_theme.button_disabled_bg
		// See button_at: one disabled ink across every surface.
		fg = style_theme.fg_disabled
		border = {}
	}
	draw_rounded_fill(frame, rrect, .MD, bg)
	if style == .Primary && enabled do btn_gloss(frame, style_theme, rrect)
	draw_rounded_border(frame, rrect, .MD, .Hairline, border)
	if enabled && focus_opt_focused(focus) do draw_focus_ring(frame, x, y, w, h)
	label_s, text_w := btn_label_fit(frame, label, w, fs)
	draw_text_string_frame(frame, label_s, x + (w - text_w) / 2, y + (h - fs) / 2, fs, fg)
	if semantic_will_emit(frame) {
		sem: Sem_State
		if !enabled do sem += {.Disabled}
		semantic_push(frame, .Button, rect, label, sem, focus, widget = widget)
	}
	return clicked && enabled
}

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
		hl_w := measure_text_frame(frame, span_c, font_size)
		draw_rectangle(frame, hl_x, y, hl_w, line_height, ui_frame_theme(frame).bg_selection)
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
	pill_h := font_size + 4
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
@(private = "file")
is_identifier_byte :: proc(value: u8) -> bool {
	return(
		(value >= 'a' && value <= 'z') ||
		(value >= 'A' && value <= 'Z') ||
		(value >= '0' && value <= '9') ||
		value == '_' ||
		value >= 0x80 \
	)
}

// Find word boundaries around a byte offset. A word is alphanumeric,
// underscore, or any non-ASCII rune.
find_word_bounds :: proc(text: string, byte_offset: int) -> (start: int, end: int) {
	assert(byte_offset >= 0 && byte_offset <= len(text))
	start = byte_offset
	for start > 0 {
		if !is_identifier_byte(text[start - 1]) do break
		start -= 1
	}
	end = byte_offset
	for end < len(text) {
		if !is_identifier_byte(text[end]) do break
		end += 1
	}
	return
}

// ------------------------------------------------------------------
// ingot-only generic widgets (not present in the alloy superset).
// ------------------------------------------------------------------

Spinner_Style :: enum {
	Arc,
	Orbit_Dots,
}

Spinner_Options :: struct {
	style:              Spinner_Style,
	radius:             f32,
	color:              Color,
	segments:           i32,
	dot_count:          i32,
	dot_radius:         f32,
	speed:              f32,
	animation_interval: f64,
}

// spinner_at centres the indicator in rect; the radius is half the smaller
// side unless options.radius overrides it.
spinner_at :: proc(frame: ^Ui_Frame, rect: Rect_I32, options: Spinner_Options = {}) {
	assert(frame != nil && frame.open, "spinner_at: invalid frame")
	assert(options.dot_count >= 0, "spinner_at: negative dot count")
	cx := rect.x + rect.w / 2
	cy := rect.y + rect.h / 2
	radius := options.radius if options.radius > 0 else f32(min(rect.w, rect.h)) / 2
	if ui_frame_drop_degenerate(frame, radius <= 0) do return
	color := options.color
	if color == {} || color == THEME_COLOR do color = ui_frame_theme(frame).fg_accent_light
	// Reduced motion freezes the indicator at phase zero and schedules no
	// repaint, matching the caret's contract in text_input.odin: the widget
	// stays legible as a busy affordance without animating. Without this the
	// spinner alone kept an idle, event-driven application repainting forever.
	reduced := ui_frame_theme(frame).reduced_motion
	angle: f32
	if !reduced {
		interval := options.animation_interval if options.animation_interval > 0 else 1.0 / 60.0
		request_redraw_in(frame, interval)
		speed := options.speed if options.speed > 0 else 1.0
		angle = f32(frame_input(frame).time) * speed
	}
	if options.style == .Orbit_Dots {
		count := options.dot_count if options.dot_count > 0 else 3
		count = min(count, 16)
		dot_radius := options.dot_radius if options.dot_radius > 0 else max(radius * 0.3, 1.0)
		for index in 0 ..< count {
			phase := f32(index) * (2 * math.PI / f32(count))
			center := Vector2 {
				f32(cx) + math.cos(angle + phase) * radius,
				f32(cy) + math.sin(angle + phase) * radius,
			}
			dot_color := color
			dot_color.a = u8(clamp(120 + index * 135 / max(count - 1, 1), 0, 255))
			draw_circle_v(frame, center, dot_radius, dot_color)
		}
		return
	}
	segments := options.segments if options.segments > 0 else 24
	segments = min(segments, 128)
	start := f32(math.mod(f64(angle) * 57.2957795, 360.0))
	thickness := max(radius * 0.28, 2.0)
	draw_ring(
		frame,
		{f32(cx), f32(cy)},
		radius - thickness,
		radius,
		start,
		start + 270,
		segments,
		color,
	)
}

section_header_height :: proc(frame: ^Ui_Frame) -> i32 {
	assert(frame != nil && frame.open, "section_header_height: invalid frame")
	metrics := ui_frame_metrics(frame)
	return metrics.FONT_SIZE_LABEL + ui_frame_sc(frame, 11)
}

section_header_at :: proc(frame: ^Ui_Frame, rect: Rect_I32, label: string) -> i32 {
	assert(frame != nil && frame.open, "section_header_at: invalid frame")
	x, y, w := rect.x, rect.y, rect.w
	metrics := ui_frame_metrics(frame)
	style := ui_frame_theme(frame)
	draw_text_string_frame(frame, label, x, y, metrics.FONT_SIZE_LABEL, style.fg_label)
	draw_rectangle(
		frame,
		x,
		y + metrics.FONT_SIZE_LABEL + ui_frame_sc(frame, 5),
		w,
		1,
		style.border_subtle,
	)
	return y + section_header_height(frame)
}

// status_pill_at draws a pill whose background is the fg color tinted to
// PILL_TINT_ALPHA. Only rect's origin is used: the pill is content-sized, and
// its measured width is returned so callers can advance a cursor.
status_pill_at :: proc(
	frame: ^Ui_Frame,
	rect: Rect_I32,
	text: string,
	font_size: i32,
	color: Color,
) -> i32 {
	assert(frame != nil, "status_pill_at: nil frame")
	return draw_pill(
		frame,
		text,
		rect.x,
		rect.y,
		font_size,
		color,
		{color.r, color.g, color.b, PILL_TINT_ALPHA},
	)
}

Progress_Orientation :: enum {
	Horizontal,
	Vertical,
}

Progress_Bar_Options :: struct {
	orientation: Progress_Orientation,
	track_color: Color,
	label:       string,
	field_id:    string,
	widget:      Widget_Id,
}

progress_bar_at :: proc(
	frame: ^Ui_Frame,
	rect: Rect_I32,
	fraction: f32,
	color: Color,
	options: Progress_Bar_Options = {},
) {
	assert(frame != nil && frame.open, "progress_bar_at: invalid frame")
	x, y, w, h := rect.x, rect.y, rect.w, rect.h
	if ui_frame_drop_degenerate(frame, w <= 0 || h <= 0) do return
	value := clamp(fraction, 0, 1)
	track_color := options.track_color
	if track_color == {} do track_color = ui_frame_theme(frame).bg_active
	track := Rectangle{f32(x), f32(y), f32(w), f32(h)}
	draw_rounded_fill(frame, track, .Pill, track_color)
	if options.orientation == .Vertical {
		fill_h := f32(h) * value
		if fill_h > 0 do draw_rectangle_rec(frame, {f32(x), f32(y + h) - fill_h, f32(w), fill_h}, color)
	} else {
		fill_w := f32(w) * value
		if fill_w >= f32(h) {
			draw_rounded_fill(frame, {f32(x), f32(y), fill_w, f32(h)}, .Pill, color)
		} else if fill_w > 0 {
			draw_rectangle_rec(frame, {f32(x), f32(y), fill_w, f32(h)}, color)
		}
	}
	if len(options.label) > 0 {
		semantic_push(
			frame,
			.Progress,
			{x, y, w, h},
			options.label,
			field_id = options.field_id,
			value = value,
			lo = 0,
			hi = 1,
			widget = options.widget,
		)
	}
}

// eased moves current toward target at `speed` units per second (frame-rate
// independent exponential ease). Returns the updated value for convenience.
// Guaranteed to terminate: a step that makes no f32 progress (increment
// rounds to zero at large magnitudes) snaps to target, so "redraw until
// settled" callers can never spin forever.
eased :: proc(current: ^f32, target, dt, speed: f32) -> f32 {
	assert(current != nil, "eased: nil current")
	k := clamp(speed * dt, 0, 1)
	if k != k do k = 0 // NaN dt/speed: hold position rather than poison state
	prev := current^
	current^ += (target - current^) * k
	if abs(target - current^) < 0.001 do current^ = target
	if k > 0 && current^ == prev do current^ = target // f32 stall: settle now
	return current^
}

// progress_bar_animated_at draws a progress bar whose fill eases toward frac.
// `anim` is caller-owned eased state (reset it to 0 to replay the fill).
progress_bar_animated_at :: proc(
	frame: ^Ui_Frame,
	rect: Rect_I32,
	frac: f32,
	anim: ^f32,
	color: Color,
	options: Progress_Bar_Options = {},
) {
	assert(frame != nil, "progress_bar_animated_at: nil frame")
	assert(anim != nil, "progress_bar_animated_at: nil anim")
	eased(anim, clamp(frac, 0, 1), frame_input(frame).frame_time, 10.0)
	if abs(clamp(frac, 0, 1) - anim^) >= 0.001 {
		// Still easing: keep frames coming until the fill settles.
		request_redraw(frame)
	}
	progress_bar_at(frame, rect, anim^, color, options)
}

// icon_btn_at draws a small square ghost button (for ✕ / ◀ / ▶ style glyphs).
// Returns true if clicked this frame.
icon_btn_at :: proc(
	frame: ^Ui_Frame,
	rect: Rect_I32,
	label: string,
	enabled: bool = true,
	focus: Focus_Opt = {},
	widget: Widget_Id = WIDGET_ID_NONE,
) -> bool {
	assert(frame != nil, "icon_btn_at: nil frame")
	return button_at(
		frame,
		rect,
		label,
		.Ghost,
		ui_frame_metrics(frame).FONT_SIZE_LABEL,
		enabled,
		focus = focus,
		widget = widget,
	)
}

icon_button_at :: proc(
	frame: ^Ui_Frame,
	rect: Rect_I32,
	icon: Icon,
	accessible_label: string,
	enabled: bool = true,
	focus: Focus_Opt = {},
	widget: Widget_Id = WIDGET_ID_NONE,
) -> bool {
	assert(frame != nil && frame.open, "icon_button_at: invalid frame")
	assert(accessible_label != "", "icon_button_at: empty accessible label")
	interaction := interact(frame, rect_f32(rect))
	hovered := enabled && interaction.hovered
	clicked := enabled && interaction.clicked
	if enabled {
		focus_opt_click(frame, focus, rect.x, rect.y, rect.w, rect.h)
		clicked = clicked || focus_opt_activated(frame, focus, .Button, widget)
	}
	if hovered do request_cursor(frame, .POINTING_HAND)
	if !rect_culled_frame(frame, rect) {
		theme := ui_frame_theme(frame)
		background := theme.button_hover if hovered else theme.button_bg
		foreground := theme.fg_accent if hovered else theme.fg_primary
		if !enabled {
			background = theme.button_disabled_bg
			foreground = theme.fg_disabled
		}
		draw_rounded_fill(frame, rect_f32(rect), .MD, background)
		if enabled && focus_opt_focused(focus) {
			draw_focus_ring(frame, rect.x, rect.y, rect.w, rect.h)
		}
		draw_icon_frame(frame, icon, rect, foreground)
	}
	semantics: Sem_State
	if !enabled do semantics += {.Disabled}
	semantic_push(frame, .Button, rect, accessible_label, semantics, focus, widget = widget)
	return clicked && enabled
}

// kv_row_at draws a key on the left and a right-aligned value inside rect's
// width. Only the origin and width are used; the row is one text line tall.
kv_row_at :: proc(
	frame: ^Ui_Frame,
	rect: Rect_I32,
	key, value: string,
	key_col, val_col: Color,
	font_size: i32 = 0,
) {
	assert(frame != nil && frame.open, "kv_row_at: invalid frame")
	assert(rect.w > 0, "kv_row_at: invalid width")
	x, y, w := rect.x, rect.y, rect.w
	resolved_font_size := font_size if font_size > 0 else ui_frame_metrics(frame).FONT_SIZE_LABEL
	assert(resolved_font_size > 0, "kv_row_at: invalid font size")
	value_width := measure_text_string_frame(frame, value, resolved_font_size)
	value_x := x + max(w - value_width, 0)
	key_width := max(w - value_width - ui_frame_sc(frame, 8), 0)
	draw_text_string_frame(frame, value, value_x, y, resolved_font_size, val_col)
	if key_width > 0 {
		draw_text_truncated_frame(frame, key, x, y, key_width, resolved_font_size, key_col)
	}
}

// list_row_bg_at draws the unified rounded row background for hover/selection.
list_row_bg_at :: proc(frame: ^Ui_Frame, rect: Rect_I32, selected, hovered: bool) {
	assert(frame != nil, "list_row_bg_at: nil frame")
	if selected {
		draw_surface(frame, rect_f32(rect), .Row, .Selected, radius = .SM, border = .None)
	} else if hovered {
		draw_surface(frame, rect_f32(rect), .Row, .Hover, radius = .SM, border = .None)
	}
}

// --- scroll pane -----------------------------------------------------------

// Pane is caller-owned state for a scissored, wheel-scrollable region with a
// measured content height (clamps scroll on the next frame) and a scrollbar.
Pane :: struct {
	scroll:         f32,
	content_h:      i32, // measured by pane_end, consumed next frame
	open:           bool, // set by pane_begin, cleared by pane_end (balance check)
	sbar:           Scrollbar_State, // per-pane scrollbar drag state
	// Cull band in effect before pane_begin, restored by pane_end. Saved
	// rather than reset to infinity so nested panes compose: an inner pane
	// must not widen the band its parent narrowed.
	saved_cull_top: i32,
	saved_cull_bot: i32,
}

pane_reset :: proc(p: ^Pane) {
	assert(p != nil, "pane_reset: nil p")
	p.scroll = 0
	p.content_h = 0
	p.open = false
}

// pane_begin handles wheel input over the pane rect, clamps scroll, begins the
// scissor, and returns the y cursor the caller should start drawing at. When
// `keyboard` is true and the mouse hovers the pane, PageUp/PageDown/Home/End
// and Up/Down arrows scroll it - leave it off for panes that host text inputs
// (their caret owns those keys).
pane_begin :: proc(
	frame: ^Ui_Frame,
	p: ^Pane,
	rect: Rect_I32,
	pad: i32 = 10,
	keyboard: bool = false,
) -> (
	cursor_y: i32,
) {
	assert(frame != nil, "pane_begin: nil frame")
	assert(p != nil, "pane_begin: nil p")
	x, y, w, h := rect.x, rect.y, rect.w, rect.h
	// Why assert: an already-open pane means a missing pane_end - the scissor
	// stack would corrupt every subsequent draw.
	assert(!p.open, "pane_begin: pane already begun (missing pane_end)")
	assert(w >= 0 && h >= 0, "pane_begin: negative pane size")
	p.open = true
	mouse := get_mouse_position(frame)
	hovered :=
		point_in_rect(mouse, {f32(x), f32(y), f32(w), f32(h)}) && !route_occluded(frame, mouse)
	if hovered {
		p.scroll -= get_wheel_move(frame) * f32(ui_frame_sc(frame, 24))
	}
	if keyboard && hovered {
		pane_keyboard_scroll(frame, p, h)
	}
	p.scroll = clamp(p.scroll, 0, f32(max(p.content_h - h, 0)))
	begin_pane_scissor(frame, x, y, w, h)
	// Narrow the cull band to the pane's visible rows so leaf painters can
	// skip geometry the scissor would discard at raster time. The band must
	// match the scissor exactly or widgets vanish at the pane edges; both use
	// the same y and h. Intersecting with the saved band keeps a nested pane
	// from widening its parent's.
	p.saved_cull_top = frame.text_cull_top
	p.saved_cull_bot = frame.text_cull_bottom
	set_text_cull_band_frame(
		frame,
		max(y, p.saved_cull_top),
		max(min(y + h, p.saved_cull_bot), max(y, p.saved_cull_top)),
	)
	return y + ui_frame_sc(frame, pad) - i32(p.scroll)
}

// pane_keyboard_scroll applies PageUp/PageDown/Home/End and Up/Down arrow
// scrolling to a hovered pane. Scroll is clamped by pane_begin right after.
@(private = "file")
pane_keyboard_scroll :: proc(frame: ^Ui_Frame, p: ^Pane, h: i32) {
	assert(p != nil, "pane_keyboard_scroll: nil pane")
	assert(p.open, "pane_keyboard_scroll: pane not begun")
	step := f32(ui_frame_metrics(frame).LINE_HEIGHT)
	if is_key_pressed(frame, .DOWN) || is_key_pressed_repeat(frame, .DOWN) do p.scroll += step
	if is_key_pressed(frame, .UP) || is_key_pressed_repeat(frame, .UP) do p.scroll -= step
	if is_key_pressed(frame, .PAGE_DOWN) || is_key_pressed_repeat(frame, .PAGE_DOWN) {
		p.scroll += f32(h)
	}
	if is_key_pressed(frame, .PAGE_UP) || is_key_pressed_repeat(frame, .PAGE_UP) do p.scroll -= f32(h)
	if is_key_pressed(frame, .HOME) do p.scroll = 0
	if is_key_pressed(frame, .END) do p.scroll = f32(max(p.content_h - h, 0))
}

// pane_end ends the scissor, records the measured content height from the
// caller's final y cursor, and draws/handles the scrollbar when content
// overflows the pane.
pane_end :: proc(frame: ^Ui_Frame, p: ^Pane, rect: Rect_I32, end_y: i32, pad: i32 = 10) {
	assert(frame != nil, "pane_end: nil frame")
	assert(p != nil, "pane_end: nil p")
	x, y, w, h := rect.x, rect.y, rect.w, rect.h
	// Why assert: pane_end without pane_begin would pop a scissor the pane
	// never pushed, clipping unrelated draws.
	assert(p.open, "pane_end: pane not begun")
	assert(h >= 0, "pane_end: negative pane height")
	p.open = false
	end_scissor_mode(frame)
	// Restore the enclosing band before the scrollbar draws: the scrollbar
	// sits inside the pane rect but outside the scissor, and a nested pane's
	// parent must get its own band back unchanged.
	assert(p.saved_cull_top <= p.saved_cull_bot, "pane_end: corrupt saved cull band")
	set_text_cull_band_frame(frame, p.saved_cull_top, p.saved_cull_bot)
	start_y := y + ui_frame_sc(frame, pad) - i32(p.scroll)
	p.content_h = end_y - start_y + ui_frame_sc(frame, pad)
	if p.content_h > h {
		off := scrollbar_ex(
			frame,
			&p.sbar,
			x + w - ui_frame_sc(frame, 9),
			y + ui_frame_sc(frame, 2),
			ui_frame_sc(frame, 5),
			h - ui_frame_sc(frame, 4),
			int(p.content_h),
			int(h),
			int(p.scroll),
		)
		p.scroll = f32(off)
	}
}

// --- standardized back button ----------------------------------------------

// back_btn_w returns the width the standard back button occupies for a label,
// so callers can right-align it before drawing.
back_btn_w :: proc(frame: ^Ui_Frame, label: string) -> i32 {
	assert(frame != nil, "back_btn_w: nil frame")
	txt := fmt.ctprintf("\u2190 %s", label)
	metrics := ui_frame_metrics(frame)
	return measure_text_frame(frame, txt, metrics.FONT_SIZE_LABEL) + metrics.CONTROL_GAP * 2
}

// back_btn draws the standard Ghost-style "← label" navigation button.
// Returns true if clicked this frame.
// back_btn_at is content-sized: only rect's origin is used, and the width
// comes from back_btn_w so a caller can reserve the slot before drawing.
back_btn_at :: proc(
	frame: ^Ui_Frame,
	rect: Rect_I32,
	label: string,
	focus: Focus_Opt = {},
	widget: Widget_Id = WIDGET_ID_NONE,
) -> bool {
	assert(frame != nil, "back_btn_at: nil frame")
	txt := fmt.tprintf("\u2190 %s", label)
	box := Rect_I32{rect.x, rect.y, back_btn_w(frame, label), ui_frame_sc(frame, 22)}
	return button_at(frame, box, txt, .Ghost, focus = focus, widget = widget)
}

// --- standardized collapsible section header -------------------------------

Collapsible_Header_Options :: struct {
	icon:        rune,
	right_label: string,
	font_size:   i32,
	height:      i32,
	focus:       Focus_Opt,
	field_id:    string,
	widget:      Widget_Id,
}

Collapsible_Header_Result :: struct {
	next_y:  i32,
	toggled: bool,
}

// collapsible_header_at uses rect's origin and width; the row height comes
// from options.height or the theme default.
collapsible_header_at :: proc(
	frame: ^Ui_Frame,
	rect_in: Rect_I32,
	label: string,
	open: ^bool,
	options: Collapsible_Header_Options = {},
) -> Collapsible_Header_Result {
	assert(frame != nil && frame.open, "collapsible_header_at: invalid frame")
	assert(open != nil, "collapsible_header_at: nil open state")
	x, y, w := rect_in.x, rect_in.y, rect_in.w
	if ui_frame_drop_degenerate(frame, w <= 0) do return {next_y = y}
	metrics := ui_frame_metrics(frame)
	style := ui_frame_theme(frame)
	font_size := options.font_size if options.font_size > 0 else metrics.FONT_SIZE_LABEL
	height := options.height if options.height > 0 else ui_frame_sc(frame, 26)
	rect := Rectangle{f32(x), f32(y), f32(w), f32(height)}
	interaction := interact(frame, rect)
	focus_opt_click(frame, options.focus, x, y, w, height)
	if interaction.hovered do request_cursor(frame, .POINTING_HAND)
	toggled := interaction.clicked || focus_opt_activated(frame, options.focus)
	if toggled do open^ = !open^
	if focus_opt_focused(options.focus) do draw_focus_ring(frame, x, y, w, height)

	pad := ui_frame_sc(frame, 10)
	text_y := y + (height - font_size) / 2
	indicator: cstring = "\u25BE" if open^ else "\u25B8"
	indicator_w := measure_text_frame(frame, indicator, font_size)
	draw_text_frame(frame, indicator, x + pad, text_y, font_size, style.fg_secondary)
	left := x + pad + indicator_w + ui_frame_sc(frame, 6)
	if options.icon != 0 {
		draw_codepoint_frame(frame, options.icon, left, text_y, font_size, style.fg_accent)
		left += rune_width_frame(frame, options.icon, font_size) + ui_frame_sc(frame, 6)
	}
	draw_text_string_frame(frame, label, left, text_y, font_size, style.fg_label)
	label_w := measure_text_string_frame(frame, label, font_size)
	right := x + w - pad
	if len(options.right_label) > 0 {
		right_w := measure_text_string_frame(frame, options.right_label, font_size)
		draw_text_string_frame(
			frame,
			options.right_label,
			right - right_w,
			text_y,
			font_size,
			style.fg_secondary,
		)
		right -= right_w + ui_frame_sc(frame, 8)
	}
	line_x := left + label_w + ui_frame_sc(frame, 8)
	if right > line_x {
		draw_rectangle(frame, line_x, y + height / 2, right - line_x, 1, style.border_subtle)
	}
	sem_state: Sem_State
	if open^ do sem_state += {.Expanded}
	semantic_push(
		frame,
		.Button,
		{x, y, w, height},
		label,
		sem_state,
		options.focus,
		field_id = options.field_id,
		widget = options.widget,
	)
	return {next_y = y + height, toggled = toggled}
}

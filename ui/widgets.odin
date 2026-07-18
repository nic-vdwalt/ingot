// LIB-CANDIDATE: imports only core:* and vendor:raylib.
// Widgets take plain data and return events; callers own all state.
package ui

import rl "vendor:raylib"
import "core:math"
import "core:strings"
import "core:unicode/utf8"

// Range selection for the active text input. `anchor` is where the selection
// started (mouse press / shift origin) and `extent` is the moving end; both
// are byte offsets into the owning builder and may be in either order. Only
// one input holds a selection at a time (keyed by builder pointer).
Input_Sel :: struct {
	sb:              ^strings.Builder,
	anchor:          int,
	extent:          int,
	active:          bool,
	dragging:        bool,
	last_click_time: f64,
	last_click_byte: int,
	click_count:     int,
}
input_sel: Input_Sel

// Caret blink state: the blink phase re-anchors whenever the active input's
// content or caret moves, so the caret is solid while typing and blinks when
// idle. Snapshot keyed by builder pointer + text length + caret offset.
@(private = "file") blink_sb: ^strings.Builder
@(private = "file") blink_len: int
@(private = "file") blink_cursor: int
@(private = "file") blink_anchor: f64

// Horizontal origin of the pane currently being drawn. Drawing may be
// translated by the rlgl matrix, but BeginScissorMode rectangles live in
// framebuffer space and are NOT affected by that matrix, so any in-pane
// scissor must add this offset. When not drawing a translated pane it is 0.
pane_origin_x: i32

// begin_pane_scissor starts a scissor whose x is shifted by pane_origin_x so
// it lines up with rlgl-translated drawing of the current pane.
begin_pane_scissor :: proc(x, y, w, h: i32) {
	rl.BeginScissorMode(x + pane_origin_x, y, w, h)
}

// draw_panel_header draws the unified header band used by side panels: a
// small label in the given accent color plus a hairline divider underneath.
// Returns the y just below the divider.
draw_panel_header :: proc(x, y, w: i32, label: string, accent: rl.Color = FG_LABEL) -> i32 {
	lc := strings.clone_to_cstring(label, context.temp_allocator)
	draw_text(lc, x + PADDING, y + (PANEL_HEADER_H - FONT_SIZE_SMALL) / 2, FONT_SIZE_SMALL, accent)
	rl.DrawRectangle(x, y + PANEL_HEADER_H - 1, w, 1, BORDER_SUBTLE)
	return y + PANEL_HEADER_H
}

// draw_card_bg draws the unified card container: rounded background fill +
// hairline border + optional left accent bar.
draw_card_bg :: proc(rect: rl.Rectangle, bg: rl.Color, accent: rl.Color = {}, accent_w: i32 = 0) {
	min_dim := min(rect.width, rect.height)
	if min_dim <= 0 do return
	round := (CARD_RADIUS_PX * 2) / min_dim
	if round > 1 do round = 1
	rl.DrawRectangleRounded(rect, round, 6, bg)
	rl.DrawRectangleRoundedLinesEx(rect, round, 6, 1.0, BORDER_SUBTLE)
	if accent_w > 0 {
		rl.DrawRectangle(i32(rect.x), i32(rect.y) + 2, accent_w, i32(rect.height) - 4, accent)
	}
}

// input_is_selecting reports whether a text input currently holds a selection.
input_is_selecting :: proc() -> bool {
	return input_sel.active
}

// mod_down reports whether a clipboard modifier (Cmd on macOS, Ctrl elsewhere)
// is currently held.
mod_down :: proc() -> bool {
	return rl.IsKeyDown(.LEFT_SUPER) || rl.IsKeyDown(.RIGHT_SUPER) ||
		rl.IsKeyDown(.LEFT_CONTROL) || rl.IsKeyDown(.RIGHT_CONTROL)
}

// Returns true if the mouse moved since the last frame. Used so keyboard
// arrow navigation in selection menus isn't overridden by a stationary cursor
// that happens to sit over an item.
mouse_moved :: proc() -> bool {
	delta := rl.GetMouseDelta()
	return delta.x != 0 || delta.y != 0
}

// get_wheel_move returns this frame's mouse-wheel delta scaled by a platform
// multiplier so scroll speed feels consistent across OSes.
get_wheel_move :: proc() -> f32 {
	wheel := rl.GetMouseWheelMove()
	when ODIN_OS == .Windows {
		return wheel * 5.0
	} else {
		return wheel
	}
}

// Convert this frame's mouse-wheel delta into whole row steps, carrying
// fractional remainders in accum so small trackpad deltas are not lost.
wheel_row_steps :: proc(accum: ^f32) -> int {
	wheel := get_wheel_move()
	if wheel == 0 do return 0
	if (accum^ > 0 && wheel < 0) || (accum^ < 0 && wheel > 0) {
		accum^ = 0
	}
	accum^ += wheel
	steps := int(accum^)
	accum^ -= f32(steps)
	return -steps
}

// --- Caret helpers for multi-line text inputs -------------------------------
// All offsets are byte offsets into `s` on rune boundaries. Lines are split on
// '\n' only (the input does not soft-wrap logically).

// Byte offset of the start of the logical line containing `pos`.
caret_line_start :: proc(s: string, pos: int) -> int {
	i := pos
	for i > 0 && s[i-1] != '\n' do i -= 1
	return i
}

// Byte offset of the end of the logical line containing `pos`.
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
	if pos <= 0 do return 0
	i := pos - 1
	for i > 0 && (s[i] & 0xC0) == 0x80 do i -= 1
	return i
}

// Move one rune right from `pos`, returning the new byte offset.
caret_next_rune :: proc(s: string, pos: int) -> int {
	if pos >= len(s) do return len(s)
	i := pos + 1
	for i < len(s) && (s[i] & 0xC0) == 0x80 do i += 1
	return i
}

// Word-jump left (skip trailing whitespace/newlines, then a run of non-space).
caret_word_left :: proc(s: string, pos: int) -> int {
	i := pos
	for i > 0 && (s[i-1] == ' ' || s[i-1] == '\n') do i -= 1
	for i > 0 {
		c := s[i-1]
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
	return p
}

// Insert `text` at `pos`, returning the new caret position.
caret_insert :: proc(sb: ^strings.Builder, pos: int, text: string) -> int {
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

// Rune column within `line` closest to horizontal pixel `px` (relative to the
// line's left edge). Used for mouse click-to-place caret.
caret_pixel_to_col :: proc(line: string, px: i32) -> int {
	if px <= 0 do return 0
	col := 0
	i := 0
	for i < len(line) {
		j := i + 1
		for j < len(line) && (line[j] & 0xC0) == 0x80 do j += 1
		prefix_c := strings.clone_to_cstring(line[:j], context.temp_allocator)
		w := measure_text(prefix_c, FONT_SIZE)
		if w > px {
			prev_c := strings.clone_to_cstring(line[:i], context.temp_allocator)
			pw := measure_text(prev_c, FONT_SIZE)
			if px - pw < w - px do return col
			return col + 1
		}
		col += 1
		i = j
	}
	return col
}

// Delete the rune before `pos` (backspace). Returns the new caret position.
caret_delete_prev :: proc(sb: ^strings.Builder, pos: int) -> int {
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
	old := strings.to_string(sb^)
	if pos >= len(old) do return pos
	end := caret_next_rune(old, pos)
	combined := strings.concatenate({old[:pos], old[end:]}, context.temp_allocator)
	strings.builder_reset(sb)
	strings.write_string(sb, combined)
	return pos
}

// --- Range selection helpers for text inputs --------------------------------

// Normalized selection range (lo <= hi).
input_sel_range :: proc() -> (lo, hi: int) {
	lo, hi = input_sel.anchor, input_sel.extent
	if lo > hi do lo, hi = hi, lo
	return
}

input_sel_set :: proc(sb: ^strings.Builder, anchor, extent: int) {
	input_sel.sb = sb
	input_sel.anchor = anchor
	input_sel.extent = extent
	input_sel.active = anchor != extent
}

input_sel_clear :: proc() {
	input_sel.active = false
	input_sel.dragging = false
}

// Delete the selected range from sb. Returns the new caret (range start).
@(private = "file")
selection_delete :: proc(sb: ^strings.Builder) -> int {
	old := strings.to_string(sb^)
	lo, hi := input_sel_range()
	lo = caret_clamp(old, lo)
	hi = caret_clamp(old, hi)
	if lo >= hi {
		input_sel_clear()
		return lo
	}
	combined := strings.concatenate({old[:lo], old[hi:]}, context.temp_allocator)
	strings.builder_reset(sb)
	strings.write_string(sb, combined)
	input_sel_clear()
	return lo
}

// Map a pane-local mouse position to a byte offset within the input's visible
// window. Rows clamp to the visible band; x clamps to line ends.
@(private = "file")
input_mouse_to_byte :: proc(vlines: []Wrap_Line, text: string, mouse: rl.Vector2, inner_x, text_top: i32, vis_start, vis_end: int) -> int {
	row := vis_start + int((mouse.y - f32(text_top)) / f32(LINE_HEIGHT))
	if row < vis_start do row = vis_start
	if row > vis_end - 1 do row = vis_end - 1
	if row < 0 do row = 0
	if row >= len(vlines) do row = len(vlines) - 1
	vl := vlines[row]
	line := text[vl.start:vl.end]
	col := caret_pixel_to_col(line, i32(mouse.x) - inner_x)
	return vl.start + caret_col_to_byte(line, col)
}

// Shared pre/post logic for caret navigation keys. Returns true when a
// non-shift key collapsed an active selection (Left/Right skip the move).
@(private = "file")
nav_begin :: proc(sb: ^strings.Builder, cursor: ^int, shift, collapse_to_lo: bool) -> bool {
	sel_owner := input_sel.active && input_sel.sb == sb
	if shift {
		if !sel_owner do input_sel_set(sb, cursor^, cursor^)
		return false
	}
	if sel_owner {
		lo, hi := input_sel_range()
		cursor^ = collapse_to_lo ? lo : hi
		input_sel_clear()
		return true
	}
	return false
}

@(private = "file")
nav_end :: proc(cursor: ^int, shift: bool) {
	if shift {
		input_sel.extent = cursor^
		input_sel.active = input_sel.anchor != input_sel.extent
	}
}

// --- Interactive vertical scrollbar ----------------------------------------
// Only one scrollbar can be dragged at a time, so drag state is module-level.
@(private = "file") sbar_dragging: bool
@(private = "file") sbar_grab_dy: f32

// Draw a draggable vertical scrollbar (track + thumb) and return the updated
// first-visible-row offset. total and visible are row counts.
scrollbar :: proc(x, y, w, h: i32, total, visible, offset: int) -> int {
	if total <= visible || h <= 0 {
		sbar_dragging = false
		return 0
	}
	max_off := total - visible
	off := clamp(offset, 0, max_off)

	rl.DrawRectangle(x, y, w, h, BG_APP)
	thumb_h := max(i32(20), h * i32(visible) / i32(total))
	track_range := max(h - thumb_h, 1)
	thumb_y := y + i32(f32(track_range) * f32(off) / f32(max_off))

	mouse := rl.GetMousePosition()
	thumb_rect := rl.Rectangle{f32(x), f32(thumb_y), f32(w), f32(thumb_h)}
	track_rect := rl.Rectangle{f32(x), f32(y), f32(w), f32(h)}

	if rl.IsMouseButtonPressed(.LEFT) {
		if rl.CheckCollisionPointRec(mouse, thumb_rect) {
			sbar_dragging = true
			sbar_grab_dy = mouse.y - f32(thumb_y)
		} else if rl.CheckCollisionPointRec(mouse, track_rect) {
			// Jump: center the thumb on the click, then keep dragging.
			sbar_dragging = true
			sbar_grab_dy = f32(thumb_h) / 2
		}
	}
	if sbar_dragging {
		if rl.IsMouseButtonDown(.LEFT) {
			t := (mouse.y - sbar_grab_dy - f32(y)) / f32(track_range)
			off = clamp(int(t*f32(max_off) + 0.5), 0, max_off)
		} else {
			sbar_dragging = false
		}
	}

	// Recompute the thumb position after a drag update.
	thumb_y = y + i32(f32(track_range) * f32(off) / f32(max_off))
	thumb_hover := rl.CheckCollisionPointRec(mouse, rl.Rectangle{f32(x), f32(thumb_y), f32(w), f32(thumb_h)})
	col := BORDER_COLOR
	if sbar_dragging || thumb_hover do col = FG_ACCENT
	rl.DrawRectangleRounded(rl.Rectangle{f32(x), f32(thumb_y), f32(w), f32(thumb_h)}, 1.0, 8, col)
	return off
}

// Button visual style variants.
Btn_Style :: enum {
	Primary,   // Accent-colored bg, white text.
	Secondary, // Muted bg, brightens on hover, accent border on hover.
	Danger,    // Red-tinted bg, light-red text.
	Ghost,     // Nearly transparent, text-driven, accent color on hover.
}

// Unified button. Returns true if clicked this frame. When enabled is false
// the button renders dimmed, ignores hover/clicks, and never returns true.
btn :: proc(
	x, y, w, h: i32,
	label: string,
	style: Btn_Style = .Secondary,
	font_size: i32 = 0,
	enabled: bool = true,
) -> bool {
	fs := font_size if font_size > 0 else FONT_SIZE_SMALL
	rect := rl.Rectangle{f32(x), f32(y), f32(w), f32(h)}
	mouse := rl.GetMousePosition()
	hovered := enabled && rl.CheckCollisionPointRec(mouse, rect)
	pressed := hovered && rl.IsMouseButtonDown(.LEFT)
	clicked := hovered && rl.IsMouseButtonReleased(.LEFT)
	if hovered do request_cursor(.POINTING_HAND)

	bg, fg, border: rl.Color
	switch style {
	case .Primary:
		bg = BUTTON_PRESSED if pressed else BUTTON_HOVER if hovered else BUTTON_BG
		fg = BUTTON_TEXT
		border = FG_ACCENT if hovered else BUTTON_BG
	case .Secondary:
		bg = BG_ACTIVE if pressed else BG_HOVER if hovered else BG_ACTIVE
		fg = FG_PRIMARY if hovered else FG_SECONDARY
		border = FG_ACCENT if hovered else rl.Color{0, 0, 0, 0}
	case .Danger:
		bg = BUTTON_DANGER_BG if hovered else BUTTON_DANGER_HOVER
		fg = BUTTON_DANGER_FG
		border = FG_ERROR if hovered else rl.Color{0, 0, 0, 0}
	case .Ghost:
		bg = BG_HOVER if hovered else rl.Color{0, 0, 0, 0}
		fg = FG_ACCENT_LIGHT if hovered else FG_SECONDARY
		border = rl.Color{0, 0, 0, 0}
	}
	if !enabled {
		bg = BUTTON_DISABLED_BG
		fg = FG_MUTED_DIM
		border = rl.Color{0, 0, 0, 0}
	}

	rl.DrawRectangleRounded(rect, BTN_ROUNDNESS, BTN_SEGMENTS, bg)
	if border.a > 0 {
		rl.DrawRectangleRoundedLinesEx(rect, BTN_ROUNDNESS, BTN_SEGMENTS, BTN_BORDER_W, border)
	}

	label_c := strings.clone_to_cstring(label, context.temp_allocator)
	text_w := measure_text(label_c, fs)
	draw_text(label_c, x + (w - text_w) / 2, y + (h - fs) / 2, fs, fg)

	return clicked && enabled
}

// Indeterminate spinner: a rotating ring arc centered at (cx, cy). Phase is
// derived from wall time (same absolute-phase pattern as the caret blink), so
// no per-widget state is needed.
spinner :: proc(cx, cy: i32, radius: f32, color: rl.Color = FG_ACCENT_LIGHT) {
	start := f32(math.mod(rl.GetTime()*360.0, 360.0))
	thickness := max(radius * 0.28, 2.0)
	rl.DrawRing(
		rl.Vector2{f32(cx), f32(cy)},
		radius - thickness, radius,
		start, start + 270.0,
		24, color,
	)
}

// Build the soft-wrapped visual lines for an input's text. Each logical line
// (split on '\n') is word-wrapped to inner_w; the returned ranges are absolute
// byte offsets into `text`. Always returns at least one (possibly empty) line.
@(private = "file")
IVL_Key :: struct { hash: u64, len: int, width: i32 }
@(private = "file") ivl_key: IVL_Key
@(private = "file") ivl_val: []Wrap_Line
@(private = "file") ivl_valid: bool

// invalidate_input_visual_lines drops the composer's wrapped-line memo. Call
// when the UI scale changes (the memo key omits font size).
invalidate_input_visual_lines :: proc() {
	ivl_valid = false
}

input_visual_lines :: proc(text: string, inner_w: i32) -> []Wrap_Line {
	key := IVL_Key{hash = fnv1a64(text), len = len(text), width = inner_w}
	if ivl_valid && key == ivl_key {
		return ivl_val
	}
	vlines := make([dynamic]Wrap_Line, context.temp_allocator)
	base := 0
	for logical in strings.split(text, "\n", context.temp_allocator) {
		for seg in wrap_text(logical, inner_w, FONT_SIZE) {
			append(&vlines, Wrap_Line{base + seg.start, base + seg.end})
		}
		base += len(logical) + 1 // +1 for the consumed '\n'
	}
	if len(vlines) == 0 do append(&vlines, Wrap_Line{0, 0})
	// Persist a copy so the memo survives the temp allocator reset.
	if ivl_valid do delete(ivl_val)
	ivl_val = make([]Wrap_Line, len(vlines))
	copy(ivl_val, vlines[:])
	ivl_key = key
	ivl_valid = true
	return ivl_val
}

// Map a byte offset to its visual (soft-wrapped) row and pixel x within the row.
input_caret_visual :: proc(vlines: []Wrap_Line, text: string, pos: int) -> (row: int, x_px: i32) {
	for vl, idx in vlines {
		if pos <= vl.end {
			p := pos
			if p < vl.start do p = vl.start
			c := strings.clone_to_cstring(text[vl.start:p], context.temp_allocator)
			return idx, measure_text(c, FONT_SIZE)
		}
	}
	if len(vlines) > 0 {
		vl := vlines[len(vlines) - 1]
		c := strings.clone_to_cstring(text[vl.start:vl.end], context.temp_allocator)
		return len(vlines) - 1, measure_text(c, FONT_SIZE)
	}
	return 0, 0
}

// Draw a text input box. Returns true if Enter was pressed.
// When masked is true, displays asterisks instead of actual text (passwords).
// `cursor` is an optional byte-offset caret; pass nil for single-line, end-
// anchored inputs. When non-nil the input supports Left/Right/Up/Down/Home/End
// navigation and inserts/deletes at the caret. `desired_col` (optional)
// remembers the rune column across vertical moves and `scroll_line` (optional)
// persists the top visible logical line.
text_input :: proc(x, y, w, h: i32, sb: ^strings.Builder, placeholder: string, active: bool, masked: bool = false, cursor: ^int = nil, desired_col: ^int = nil, scroll_line: ^int = nil) -> bool {
	rect := rl.Rectangle{f32(x), f32(y), f32(w), f32(h)}
	bg := BG_INPUT if active else BG_SECONDARY
	rl.DrawRectangleRounded(rect, BTN_ROUNDNESS, BTN_SEGMENTS, bg)
	rl.DrawRectangleRoundedLinesEx(rect, BTN_ROUNDNESS, BTN_SEGMENTS, BTN_BORDER_W, BORDER_COLOR if !active else FG_ACCENT)

	entered := false

	// Whether this input owns the current selection.
	sel_owner := input_sel.active && input_sel.sb == sb

	// Whether this input uses the caret model.
	caret_active := cursor != nil

	if active {
		mods := mod_down()
		shift := rl.IsKeyDown(.LEFT_SHIFT) || rl.IsKeyDown(.RIGHT_SHIFT)

		// A selection owned by a different (now unfocused / possibly dead)
		// builder is stale — drop it so its pointer is never trusted.
		if input_sel.active && input_sel.sb != sb {
			input_sel_clear()
			sel_owner = false
		}
		// Clamp against external buffer rewrites.
		if sel_owner {
			s := strings.to_string(sb^)
			input_sel.anchor = caret_clamp(s, input_sel.anchor)
			input_sel.extent = caret_clamp(s, input_sel.extent)
			input_sel.active = input_sel.anchor != input_sel.extent
			sel_owner = input_sel.active
		}

		// Keep the caret within bounds (the buffer may have been rewritten).
		if caret_active {
			cursor^ = caret_clamp(strings.to_string(sb^), cursor^)
		}

		// Non-caret inputs: clicking inside clears the selection.
		if !caret_active && sel_owner && rl.IsMouseButtonPressed(.LEFT) {
			if rl.CheckCollisionPointRec(rl.GetMousePosition(), rect) {
				input_sel_clear()
				sel_owner = false
			}
		}

		// Select all (Cmd/Ctrl+A).
		if mods && rl.IsKeyPressed(.A) {
			if strings.builder_len(sb^) > 0 {
				input_sel_set(sb, 0, strings.builder_len(sb^))
				if caret_active do cursor^ = strings.builder_len(sb^)
				sel_owner = input_sel.active
			}
		}

		// Copy (Cmd/Ctrl+C) — copies the selected range.
		if mods && rl.IsKeyPressed(.C) && sel_owner {
			s := strings.to_string(sb^)
			lo, hi := input_sel_range()
			if lo < hi && hi <= len(s) {
				rl.SetClipboardText(strings.clone_to_cstring(s[lo:hi], context.temp_allocator))
			}
		}

		// Cut (Cmd/Ctrl+X) — copies the selected range then deletes it.
		if mods && rl.IsKeyPressed(.X) && sel_owner {
			s := strings.to_string(sb^)
			lo, hi := input_sel_range()
			if lo < hi && hi <= len(s) {
				rl.SetClipboardText(strings.clone_to_cstring(s[lo:hi], context.temp_allocator))
				nc := selection_delete(sb)
				if caret_active do cursor^ = nc
				sel_owner = false
			}
		}

		// Handle character input. Ignore characters while a modifier is held
		// so shortcuts (Cmd+A/C/X/V) don't insert their letters.
		for {
			ch := rl.GetCharPressed()
			if ch == 0 do break
			if mods do continue
			// Typing over a selection replaces it.
			if sel_owner {
				nc := selection_delete(sb)
				if caret_active do cursor^ = nc
				sel_owner = false
			}
			if caret_active {
				buf, n := utf8.encode_rune(rune(ch))
				cursor^ = caret_insert(sb, cursor^, string(buf[:n]))
			} else if strings.builder_len(sb^) < INPUT_MAX_LEN {
				strings.write_rune(sb, rune(ch))
			}
		}

		// Handle paste (Cmd+V / Ctrl+V).
		if rl.IsKeyPressed(.V) && mods {
			clip := rl.GetClipboardText()
			if clip != nil && len(string(clip)) > 0 {
				if sel_owner {
					nc := selection_delete(sb)
					if caret_active do cursor^ = nc
					sel_owner = false
				}
				clip_str := string(clip)
				if caret_active {
					cursor^ = caret_insert(sb, cursor^, clip_str)
				} else {
					for ch in clip_str {
						if strings.builder_len(sb^) >= INPUT_MAX_LEN do break
						strings.write_rune(sb, ch)
					}
				}
			}
		}

		// Handle backspace.
		if rl.IsKeyPressed(.BACKSPACE) || rl.IsKeyPressedRepeat(.BACKSPACE) {
			if sel_owner {
				nc := selection_delete(sb)
				if caret_active do cursor^ = nc
				sel_owner = false
			} else if caret_active {
				cursor^ = caret_delete_prev(sb, cursor^)
			} else {
				s := strings.to_string(sb^)
				if len(s) > 0 {
					// Remove last rune.
					last_rune_start := len(s)
					for last_rune_start > 0 {
						last_rune_start -= 1
						if (s[last_rune_start] & 0xC0) != 0x80 do break
					}
					strings.builder_reset(sb)
					strings.write_string(sb, s[:last_rune_start])
				}
			}
		}

		// Handle forward delete.
		if caret_active && (rl.IsKeyPressed(.DELETE) || rl.IsKeyPressedRepeat(.DELETE)) {
			if sel_owner {
				cursor^ = selection_delete(sb)
				sel_owner = false
			} else {
				cursor^ = caret_delete_next(sb, cursor^)
			}
		}

		// Handle Enter (submit).
		if rl.IsKeyPressed(.ENTER) && !rl.IsKeyDown(.LEFT_SHIFT) && !rl.IsKeyDown(.RIGHT_SHIFT) {
			entered = true
			input_sel_clear()
			sel_owner = false
		}

		// Handle Shift+Enter (insert newline).
		if rl.IsKeyPressed(.ENTER) && (rl.IsKeyDown(.LEFT_SHIFT) || rl.IsKeyDown(.RIGHT_SHIFT)) {
			if sel_owner {
				nc := selection_delete(sb)
				if caret_active do cursor^ = nc
				sel_owner = false
			}
			if caret_active {
				cursor^ = caret_insert(sb, cursor^, "\n")
			} else if strings.builder_len(sb^) < INPUT_MAX_LEN {
				strings.write_byte(sb, '\n')
			}
		}

		// Caret navigation (only for caret-aware inputs). Shift extends the
		// selection; a plain move collapses it to the appropriate end.
		if caret_active {
			s := strings.to_string(sb^)
			word := rl.IsKeyDown(.LEFT_ALT) || rl.IsKeyDown(.RIGHT_ALT)
			moved_vert := false

			if rl.IsKeyPressed(.LEFT) || rl.IsKeyPressedRepeat(.LEFT) {
				if !nav_begin(sb, cursor, shift, true) {
					cursor^ = word ? caret_word_left(s, cursor^) : caret_prev_rune(s, cursor^)
				}
				nav_end(cursor, shift)
			}
			if rl.IsKeyPressed(.RIGHT) || rl.IsKeyPressedRepeat(.RIGHT) {
				if !nav_begin(sb, cursor, shift, false) {
					cursor^ = word ? caret_word_right(s, cursor^) : caret_next_rune(s, cursor^)
				}
				nav_end(cursor, shift)
			}
			if rl.IsKeyPressed(.UP) || rl.IsKeyPressedRepeat(.UP) {
				nav_begin(sb, cursor, shift, true)
				row, col := caret_row_col(s, cursor^)
				want := col
				if desired_col != nil do want = max(desired_col^, col)
				if row > 0 {
					cursor^ = caret_from_row_col(s, row - 1, want)
					moved_vert = true
				}
				nav_end(cursor, shift)
			}
			if rl.IsKeyPressed(.DOWN) || rl.IsKeyPressedRepeat(.DOWN) {
				nav_begin(sb, cursor, shift, false)
				row, col := caret_row_col(s, cursor^)
				want := col
				if desired_col != nil do want = max(desired_col^, col)
				if row < caret_line_count(s) - 1 {
					cursor^ = caret_from_row_col(s, row + 1, want)
					moved_vert = true
				}
				nav_end(cursor, shift)
			}
			if rl.IsKeyPressed(.HOME) {
				nav_begin(sb, cursor, shift, true)
				cursor^ = mods ? 0 : caret_line_start(s, cursor^)
				nav_end(cursor, shift)
			}
			if rl.IsKeyPressed(.END) {
				nav_begin(sb, cursor, shift, false)
				cursor^ = mods ? len(s) : caret_line_end(s, cursor^)
				nav_end(cursor, shift)
			}
			sel_owner = input_sel.active && input_sel.sb == sb

			// Remember the column for vertical movement; refresh it after any
			// horizontal move or edit so Up/Down start from the right column.
			if desired_col != nil && !moved_vert {
				_, c := caret_row_col(strings.to_string(sb^), cursor^)
				desired_col^ = c
			}
		}
	}

	// Clip all drawing to the input rect interior.
	inner_x := x + PADDING
	inner_w := w - PADDING * 2
	begin_pane_scissor(inner_x, y, inner_w, h)

	// Draw text or placeholder.
	text := strings.to_string(sb^)
	has_newlines := !masked && strings.contains_rune(text, '\n')

	// Precompute layout for the caret-aware (soft-wrapping) renderer. Visual
	// rows are render-only; caret navigation still uses logical lines.
	use_caret_render := caret_active && !masked
	visible_lines := max(1, (h - 12) / LINE_HEIGHT)
	vlines: []Wrap_Line
	vis_start: int
	vis_end: int
	cur_vrow: int
	cur_caret_x: i32
	if use_caret_render {
		vlines = input_visual_lines(text, inner_w)
		cur_vrow, cur_caret_x = input_caret_visual(vlines, text, cursor^)
		vis_start = scroll_line^ if scroll_line != nil else max(0, len(vlines) - int(visible_lines))
		if cur_vrow < vis_start do vis_start = cur_vrow
		if cur_vrow >= vis_start + int(visible_lines) do vis_start = cur_vrow - int(visible_lines) + 1
		if vis_start < 0 do vis_start = 0
		// Never scroll further than needed to fill the visible window.
		max_start := max(0, len(vlines) - int(visible_lines))
		if vis_start > max_start do vis_start = max_start
		if scroll_line != nil do scroll_line^ = vis_start
		vis_end = min(len(vlines), vis_start + int(visible_lines))
	}

	// Vertical origin of the first visual text row. Single-line caret inputs
	// center the text in the box (matching the placeholder / legacy single-
	// line paths); multi-line composers keep the fixed top padding.
	text_top := y + 6
	if use_caret_render && !has_newlines && len(vlines) <= 1 {
		text_top = y + (h - FONT_SIZE) / 2
	}

	// Mouse selection (caret inputs): press places the caret / starts a drag,
	// double-click selects a word, triple-click the logical line, drag extends
	// by character.
	if active && use_caret_render {
		mouse := rl.GetMousePosition()
		mouse.x -= f32(pane_origin_x)
		if rl.IsMouseButtonPressed(.LEFT) {
			if rl.CheckCollisionPointRec(mouse, rect) {
				off := input_mouse_to_byte(vlines, text, mouse, inner_x, text_top, vis_start, vis_end)
				now := rl.GetTime()
				if now - input_sel.last_click_time < 0.4 && abs(off - input_sel.last_click_byte) <= 2 {
					input_sel.click_count = min(input_sel.click_count + 1, 3)
				} else {
					input_sel.click_count = 1
				}
				input_sel.last_click_time = now
				input_sel.last_click_byte = off
				switch input_sel.click_count {
				case 2:
					ws, we := find_word_bounds(text, off)
					input_sel_set(sb, ws, we)
					input_sel.dragging = true
					cursor^ = we
				case 3:
					ls := caret_line_start(text, off)
					le := caret_line_end(text, off)
					input_sel_set(sb, ls, le)
					input_sel.dragging = false
					cursor^ = le
				case:
					cursor^ = off
					input_sel_set(sb, cursor^, cursor^)
					input_sel.dragging = true
				}
				if desired_col != nil {
					_, c := caret_row_col(text, cursor^)
					desired_col^ = c
				}
			} else if input_sel.sb == sb {
				input_sel_clear()
			}
		}
		if input_sel.dragging && input_sel.sb == sb && rl.IsMouseButtonDown(.LEFT) {
			off := input_mouse_to_byte(vlines, text, mouse, inner_x, text_top, vis_start, vis_end)
			if off != input_sel.extent {
				input_sel.extent = off
				input_sel.active = input_sel.anchor != input_sel.extent
				cursor^ = off
			}
		}
		if input_sel.dragging && rl.IsMouseButtonReleased(.LEFT) {
			input_sel.dragging = false
			if input_sel.anchor == input_sel.extent do input_sel.active = false
		}
		// The mouse may have moved the caret this frame — refresh its visual
		// position so the caret and highlight don't lag one frame.
		cur_vrow, cur_caret_x = input_caret_visual(vlines, text, cursor^)
	}

	// Legacy (non-caret) render paths only show a highlight when the selection
	// covers the whole text (Cmd+A on simple inputs).
	sel_all := input_sel.active && input_sel.sb == sb &&
		min(input_sel.anchor, input_sel.extent) == 0 &&
		max(input_sel.anchor, input_sel.extent) == len(text)

	if len(text) == 0 {
		ph_c := strings.clone_to_cstring(placeholder, context.temp_allocator)
		draw_text(ph_c, inner_x, y + (h - FONT_SIZE) / 2, FONT_SIZE, FG_SECONDARY)
	} else if use_caret_render {
		// Caret-aware soft-wrapped rendering: draw a window of visual lines.
		render_idx: i32 = 0
		for vi := vis_start; vi < vis_end; vi += 1 {
			vl := vlines[vi]
			line := text[vl.start:vl.end]
			line_c := strings.clone_to_cstring(line, context.temp_allocator)
			line_y := text_top + render_idx * LINE_HEIGHT
			// Selection highlight: overlap of this visual line with the range.
			if input_sel.active && input_sel.sb == sb {
				lo, hi := input_sel_range()
				hs := max(lo, vl.start)
				he := min(hi, vl.end)
				if hs < he {
					pre_c := strings.clone_to_cstring(text[vl.start:hs], context.temp_allocator)
					hx := inner_x + measure_text(pre_c, FONT_SIZE)
					span_c := strings.clone_to_cstring(text[hs:he], context.temp_allocator)
					hw := measure_text(span_c, FONT_SIZE)
					rl.DrawRectangle(hx, line_y, hw, FONT_SIZE, BG_SELECTION)
				}
			}
			draw_text(line_c, inner_x, line_y, FONT_SIZE, FG_PRIMARY)
			render_idx += 1
		}
	} else if has_newlines {
		// Multiline rendering: split by newlines and show bottom lines.
		lines := strings.split(text, "\n", context.temp_allocator)
		start_line := max(0, i32(len(lines)) - visible_lines)
		render_idx: i32 = 0
		for i := start_line; i < i32(len(lines)); i += 1 {
			line := lines[i]
			line_c := strings.clone_to_cstring(line, context.temp_allocator)
			line_y := y + 6 + render_idx * LINE_HEIGHT
			// Only the last line gets horizontal scrolling (cursor at end).
			if i == i32(len(lines)) - 1 {
				line_pixel_w := measure_text(line_c, FONT_SIZE)
				line_offset: i32 = 0
				if line_pixel_w > inner_w {
					line_offset = line_pixel_w - inner_w
				}
				if sel_all {
					hl_w := min(line_pixel_w, inner_w)
					rl.DrawRectangle(inner_x, line_y, hl_w, FONT_SIZE, BG_SELECTION)
				}
				draw_text(line_c, inner_x - line_offset, line_y, FONT_SIZE, FG_PRIMARY)
			} else {
				if sel_all {
					hl_w := min(measure_text(line_c, FONT_SIZE), inner_w)
					rl.DrawRectangle(inner_x, line_y, hl_w, FONT_SIZE, BG_SELECTION)
				}
				draw_text(line_c, inner_x, line_y, FONT_SIZE, FG_PRIMARY)
			}
			render_idx += 1
		}
	} else {
		// Single-line rendering.
		display_text: string
		if masked {
			mask_sb := strings.builder_make(context.temp_allocator)
			for _ in text {
				strings.write_byte(&mask_sb, '*')
			}
			display_text = strings.to_string(mask_sb)
		} else {
			display_text = text
		}
		display_c := strings.clone_to_cstring(display_text, context.temp_allocator)
		text_pixel_w := measure_text(display_c, FONT_SIZE)
		text_offset: i32 = 0
		if text_pixel_w > inner_w {
			text_offset = text_pixel_w - inner_w
		}
		if sel_all {
			hl_w := min(text_pixel_w, inner_w)
			rl.DrawRectangle(inner_x, y + (h - FONT_SIZE) / 2, hl_w, FONT_SIZE, BG_SELECTION)
		}
		draw_text(display_c, inner_x - text_offset, y + (h - FONT_SIZE) / 2, FONT_SIZE, FG_PRIMARY)
	}

	// Draw cursor if active.
	if active {
		t := rl.GetTime()
		// Re-anchor the blink phase on any edit or caret movement.
		cur := cursor^ if cursor != nil else strings.builder_len(sb^)
		if blink_sb != sb || blink_len != strings.builder_len(sb^) || blink_cursor != cur {
			blink_sb = sb
			blink_len = strings.builder_len(sb^)
			blink_cursor = cur
			blink_anchor = t
		}
		caret_w := max(i32(1), sc(1))
		if int((t-blink_anchor)*2)%2 == 0 {
			if use_caret_render {
				// Caret at its true visual (row, x) within the visible window.
				if cur_vrow >= vis_start && cur_vrow < vis_end {
					cursor_x := inner_x + cur_caret_x
					cursor_line_y := text_top + i32(cur_vrow - vis_start) * LINE_HEIGHT
					rl.DrawRectangle(cursor_x, cursor_line_y, caret_w, FONT_SIZE, FG_ACCENT_LIGHT)
				}
			} else if has_newlines {
				// Multiline cursor: position at end of last line.
				lines := strings.split(text, "\n", context.temp_allocator)
				last_line := lines[len(lines) - 1]
				last_line_c := strings.clone_to_cstring(last_line, context.temp_allocator)
				cursor_text_w := measure_text(last_line_c, FONT_SIZE)
				cursor_offset: i32 = 0
				if cursor_text_w > inner_w {
					cursor_offset = cursor_text_w - inner_w
				}
				cursor_x := inner_x + cursor_text_w - cursor_offset
				visible_count := min(i32(len(lines)), visible_lines)
				cursor_line_y := y + 6 + (visible_count - 1) * LINE_HEIGHT
				rl.DrawRectangle(cursor_x, cursor_line_y, caret_w, FONT_SIZE, FG_ACCENT_LIGHT)
			} else {
				// Single-line cursor.
				display_for_cursor: string
				if masked {
					mask_sb := strings.builder_make(context.temp_allocator)
					for _ in text {
						strings.write_byte(&mask_sb, '*')
					}
					display_for_cursor = strings.to_string(mask_sb)
				} else {
					display_for_cursor = text
				}
				cursor_text_w := measure_text(strings.clone_to_cstring(display_for_cursor, context.temp_allocator), FONT_SIZE)
				cursor_offset: i32 = 0
				if cursor_text_w > inner_w {
					cursor_offset = cursor_text_w - inner_w
				}
				cursor_x := inner_x + cursor_text_w - cursor_offset
				rl.DrawRectangle(cursor_x, y + 5, caret_w, h - 10, FG_ACCENT_LIGHT)
			}
		}
	}

	rl.EndScissorMode()

	return entered
}

// Hit-test wrapped text. Returns byte offset into text at (mouse_x, mouse_y),
// or -1 if miss. Must mirror draw_text_wrapped wrapping logic exactly.
hit_test_wrapped :: proc(x, y, max_width: i32, text: string, mouse_x, mouse_y: i32, font_size: i32 = FONT_SIZE) -> int {
	if len(text) == 0 do return -1

	lines := wrap_text(text, max_width, font_size)
	row := int((mouse_y - y) / i32(LINE_HEIGHT))
	if row < 0 do row = 0
	if row >= len(lines) do row = len(lines) - 1
	ln := lines[row]
	line := text[ln.start:ln.end]
	col := caret_pixel_to_col(line, mouse_x - x)
	return ln.start + caret_col_to_byte(line, col)
}

// Draw a single line with optional selection highlight behind it.
draw_line_with_selection :: proc(x, y: i32, line: string, font_size: i32, color: rl.Color, line_byte_start, sel_start, sel_end: int) {
	line_byte_end := line_byte_start + len(line)

	// Compute overlap of [line_byte_start, line_byte_end) and [sel_start, sel_end).
	hl_start := max(sel_start, line_byte_start)
	hl_end := min(sel_end, line_byte_end)

	if hl_start < hl_end {
		local_start := hl_start - line_byte_start
		local_end := hl_end - line_byte_start
		prefix_c := strings.clone_to_cstring(line[:local_start], context.temp_allocator)
		hl_x := x + measure_text(prefix_c, font_size)
		span_c := strings.clone_to_cstring(line[local_start:local_end], context.temp_allocator)
		hl_w := measure_text(span_c, font_size)
		rl.DrawRectangle(hl_x, y, hl_w, i32(LINE_HEIGHT), BG_SELECTION)
	}

	line_c := strings.clone_to_cstring(line, context.temp_allocator)
	draw_text(line_c, x, y, font_size, color)
}

// Vertical viewport cull band for wrapped-text draw loops. When set, per-line
// drawing skips lines fully outside [top, bottom] while still advancing layout
// so heights stay correct. Defaults to unbounded.
@(private = "file") text_cull_top: i32 = min(i32)
@(private = "file") text_cull_bottom: i32 = max(i32)

// set_text_cull_band restricts subsequent wrapped-text draws to the given
// vertical band. Pair with clear_text_cull_band.
set_text_cull_band :: proc(top, bottom: i32) {
	text_cull_top = top
	text_cull_bottom = bottom
}

// clear_text_cull_band restores unbounded drawing.
clear_text_cull_band :: proc() {
	text_cull_top = min(i32)
	text_cull_bottom = max(i32)
}

// line_culled reports whether a line drawn at y (height LINE_HEIGHT) is fully
// outside the active cull band.
line_culled :: proc(y: i32) -> bool {
	return y + LINE_HEIGHT < text_cull_top || y > text_cull_bottom
}

// Draw a scrollable text area with optional selection highlighting.
draw_text_wrapped :: proc(x, y, max_width: i32, text: string, color: rl.Color, font_size: i32 = FONT_SIZE, sel_start: int = -1, sel_end: int = -1, draw: bool = true) -> i32 {
	if len(text) == 0 do return 0

	has_sel := sel_start >= 0 && sel_end > sel_start

	current_y := y
	for ln in wrap_text(text, max_width, font_size) {
		if line_culled(current_y) {
			current_y += i32(LINE_HEIGHT)
			continue
		}
		if !draw {
			current_y += i32(LINE_HEIGHT)
			continue
		}
		line := text[ln.start:ln.end]
		if has_sel {
			draw_line_with_selection(x, current_y, line, font_size, color, ln.start, sel_start, sel_end)
		} else {
			line_c := strings.clone_to_cstring(line, context.temp_allocator)
			draw_text(line_c, x, current_y, font_size, color)
		}
		current_y += i32(LINE_HEIGHT)
	}

	return current_y - y
}

// Draw a single line of text, cutting it with an ellipsis if it would exceed
// max_width.
draw_text_truncated :: proc(text: string, x, y, max_width, font_size: i32, color: rl.Color) {
	if len(text) == 0 do return
	out := truncate_to_width(text, max_width, font_size)
	out_c := strings.clone_to_cstring(out, context.temp_allocator)
	draw_text(out_c, x, y, font_size, color)
}

// Draw a rounded "pill" badge with text. Returns the pill's full width so the
// caller can advance horizontally.
draw_pill :: proc(text: string, x, y, font_size: i32, fg, bg: rl.Color) -> i32 {
	c := strings.clone_to_cstring(text, context.temp_allocator)
	tw := measure_text(c, font_size)
	pad_h: i32 = 6
	pill_w := tw + pad_h * 2
	pill_h := font_size + 4
	rect := rl.Rectangle{f32(x), f32(y), f32(pill_w), f32(pill_h)}
	rl.DrawRectangleRounded(rect, 0.6, 6, bg)
	draw_text(c, x + pad_h, y + 2, font_size, fg)
	return pill_w
}

// Return text truncated with a trailing ellipsis so it fits within max_width.
// The returned string is allocated in the temp allocator.
truncate_to_width :: proc(text: string, max_width, font_size: i32) -> string {
	if len(text) == 0 do return text
	full_c := strings.clone_to_cstring(text, context.temp_allocator)
	if measure_text(full_c, font_size) <= max_width {
		return text
	}
	ell_c := strings.clone_to_cstring("…", context.temp_allocator)
	ell_w := measure_text(ell_c, font_size)
	avail := max_width - ell_w
	// Walk runes accumulating width until we run out of room.
	end := 0
	for end < len(text) {
		next := end + 1
		for next < len(text) && (text[next] & 0xC0) == 0x80 do next += 1
		seg_c := strings.clone_to_cstring(text[:next], context.temp_allocator)
		if measure_text(seg_c, font_size) > avail do break
		end = next
	}
	return strings.concatenate({text[:end], "…"}, context.temp_allocator)
}

// Find word boundaries around a byte offset. A word is alphanumeric + underscore.
find_word_bounds :: proc(text: string, byte_offset: int) -> (start: int, end: int) {
	start = byte_offset
	for start > 0 {
		c := text[start - 1]
		if !((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_') do break
		start -= 1
	}
	end = byte_offset
	for end < len(text) {
		c := text[end]
		if !((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_') do break
		end += 1
	}
	return
}

// section_header draws an uppercase small label with a hairline underneath —
// the unified section divider used inside panels/cards. Returns the y below.
section_header :: proc(x, y, w: i32, label: string) -> i32 {
	lc := strings.clone_to_cstring(label, context.temp_allocator)
	draw_text(lc, x, y, FONT_SIZE_SMALL, FG_LABEL)
	rl.DrawRectangle(x, y + FONT_SIZE_SMALL + sc(5), w, 1, BORDER_SUBTLE)
	return y + FONT_SIZE_SMALL + sc(11)
}

// status_pill draws a pill whose background is the fg color tinted to
// PILL_TINT_ALPHA. Returns the pill width.
status_pill :: proc(text: string, x, y, font_size: i32, color: rl.Color) -> i32 {
	return draw_pill(text, x, y, font_size, color,
		{color.r, color.g, color.b, PILL_TINT_ALPHA})
}

// progress_bar draws a rounded track + fill; frac clamped to [0,1].
progress_bar :: proc(x, y, w, h: i32, frac: f32, color: rl.Color) {
	track := rl.Rectangle{f32(x), f32(y), f32(w), f32(h)}
	rl.DrawRectangleRounded(track, 1.0, 4, BG_ACTIVE)
	fw := f32(w) * clamp(frac, 0, 1)
	if fw >= f32(h) { // avoid degenerate rounding on tiny fills
		rl.DrawRectangleRounded({f32(x), f32(y), fw, f32(h)}, 1.0, 4, color)
	} else if fw > 0 {
		rl.DrawRectangleRec({f32(x), f32(y), fw, f32(h)}, color)
	}
}

// eased moves current toward target at `speed` units per second (frame-rate
// independent exponential ease). Returns the updated value for convenience.
eased :: proc(current: ^f32, target, dt, speed: f32) -> f32 {
	k := clamp(speed * dt, 0, 1)
	current^ += (target - current^) * k
	if abs(target - current^) < 0.001 do current^ = target
	return current^
}

// progress_bar_animated draws a progress bar whose fill eases toward frac.
// `anim` is caller-owned eased state (reset it to 0 to replay the fill).
progress_bar_animated :: proc(x, y, w, h: i32, frac: f32, anim: ^f32, color: rl.Color) {
	eased(anim, clamp(frac, 0, 1), rl.GetFrameTime(), 10.0)
	progress_bar(x, y, w, h, anim^, color)
}

// icon_btn draws a small square ghost button (for ✕ / ◀ / ▶ style glyphs).
// Returns true if clicked this frame.
icon_btn :: proc(x, y, size: i32, label: string, enabled: bool = true) -> bool {
	return btn(x, y, size, size, label, .Ghost, FONT_SIZE_SMALL, enabled)
}

// kv_row draws key (left, truncated) and value (right-aligned) on one line.
kv_row :: proc(x, y, w: i32, key, value: string, key_col, val_col: rl.Color, font_size: i32 = 0) {
	fs := font_size if font_size > 0 else FONT_SIZE_SMALL
	vc := strings.clone_to_cstring(value, context.temp_allocator)
	vw := measure_text(vc, fs)
	draw_text(vc, x + w - vw, y, fs, val_col)
	draw_text_truncated(key, x, y, w - vw - sc(8), fs, key_col)
}

// list_row_bg draws the unified rounded row background for hover/selection.
list_row_bg :: proc(rect: rl.Rectangle, selected, hovered: bool) {
	if selected {
		rl.DrawRectangleRounded(rect, 0.25, 4, BG_ACTIVE)
	} else if hovered {
		rl.DrawRectangleRounded(rect, 0.25, 4, BG_HOVER)
	}
}

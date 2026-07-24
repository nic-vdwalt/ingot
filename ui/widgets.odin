// LIB-CANDIDATE: imports only core:* and ingot:gfx.
// Widgets take plain data and return events; callers own all state.
// Merged from openalloy/alloy (superset input/undo/pill/split features)
// plus ingot-only generic widgets (spinner, panes, back_btn, etc.).
package ui

import "core:fmt"
import "core:math"
import "core:strings"
import rl "ingot:gfx"

// begin_pane_scissor converts pane-local geometry to screen coordinates because
// scissor rectangles are not affected by the drawing transform.
begin_pane_scissor :: proc(frame: ^Ui_Frame, x, y, w, h: i32) {
	assert(w > 0 && h > 0, "begin_pane_scissor: invalid rect")
	point := frame_to_screen(frame, {f32(x), f32(y)})
	rl.BeginScissorMode(i32(point.x), i32(point.y), w, h)
}

// draw_split_divider draws the vertical drag handle between the chat pane and
// the embedded nvim pane of a split Chat tab. x is the divider's left edge.
draw_split_divider :: proc(frame: ^Ui_Frame, x, screen_h: i32, hovered: bool) {
	assert(screen_h > 0, "draw_split_divider: invalid screen height")
	style := ui_frame_theme(frame)
	metrics := ui_frame_metrics(frame)
	col := style.border_color
	if hovered do col = style.fg_accent
	rl.DrawRectangle(
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
	accent: rl.Color = THEME_COLOR,
) -> i32 {
	assert(w > 0, "draw_panel_header: invalid width")
	style := ui_frame_theme(frame)
	metrics := ui_frame_metrics(frame)
	accent := accent
	if accent == THEME_COLOR do accent = style.fg_label
	lc := strings.clone_to_cstring(label, context.temp_allocator)
	draw_text_frame(
		frame,
		lc,
		x + metrics.PADDING,
		y + (metrics.PANEL_HEADER_H - metrics.FONT_SIZE_LABEL) / 2,
		metrics.FONT_SIZE_LABEL,
		accent,
	)
	rl.DrawRectangle(x, y + metrics.PANEL_HEADER_H - 1, w, 1, style.border_subtle)
	return y + metrics.PANEL_HEADER_H
}

// draw_card_bg draws the unified card container: rounded background fill +
// hairline border + optional left accent bar.
draw_card_bg_frame :: proc(
	frame: ^Ui_Frame,
	rect: rl.Rectangle,
	bg: rl.Color,
	accent: rl.Color = THEME_COLOR,
	accent_w: i32 = 0,
) {
	min_dim := min(rect.width, rect.height)
	if min_dim <= 0 do return
	round := (ui_frame_scf(frame, CARD_RADIUS_PX) * 2) / min_dim
	if round > 1 do round = 1
	rl.DrawRectangleRounded(rect, round, 6, bg)
	rl.DrawRectangleRoundedLinesEx(
		rect,
		round,
		6,
		ui_frame_scf(frame, 1),
		ui_frame_theme(frame).border_subtle,
	)
	if accent_w > 0 {
		inset := ui_frame_sc(frame, 2)
		rl.DrawRectangle(
			i32(rect.x),
			i32(rect.y) + inset,
			accent_w,
			i32(rect.height) - inset * 2,
			accent,
		)
	}
}

draw_card_bg :: proc(
	rect: rl.Rectangle,
	bg: rl.Color,
	accent: rl.Color = THEME_COLOR,
	accent_w: i32 = 0,
) {
	min_dim := min(rect.width, rect.height)
	if min_dim <= 0 do return
	round := (CARD_RADIUS_PX * 2) / min_dim
	if round > 1 do round = 1
	rl.DrawRectangleRounded(rect, round, 6, bg)
	rl.DrawRectangleRoundedLinesEx(rect, round, 6, 1.0, theme.border_subtle)
	if accent_w > 0 {
		rl.DrawRectangle(i32(rect.x), i32(rect.y) + 2, accent_w, i32(rect.height) - 4, accent)
	}
}

// draw_split_drop_hint previews where a tab dragged into the content area will
// land: it dims the content region and highlights the target half (left/right)
// with a divider preview down the middle.
draw_split_drop_hint :: proc(frame: ^Ui_Frame, screen_w, screen_h: i32, side_left: bool) {
	assert(screen_w > 0 && screen_h > 0, "draw_split_drop_hint: invalid screen size")
	style := ui_frame_theme(frame)
	top := ui_frame_metrics(frame).TAB_BAR_HEIGHT
	h := screen_h - top
	rl.DrawRectangle(0, top, screen_w, h, rl.Color{0, 0, 0, 70})
	half := screen_w / 2
	hl := rl.Color{style.fg_accent.r, style.fg_accent.g, style.fg_accent.b, 70}
	if side_left {
		rl.DrawRectangle(0, top, half, h, hl)
	} else {
		rl.DrawRectangle(half, top, screen_w - half, h, hl)
	}
	rl.DrawRectangle(half - ui_frame_sc(frame, 1), top, ui_frame_sc(frame, 2), h, style.fg_accent)
}

// input_is_selecting (selection queries) live in text_input.odin.

// mod_down reports whether a clipboard modifier (Cmd on macOS, Ctrl elsewhere)
// is currently held.
mod_down :: proc() -> bool {
	return(
		rl.IsKeyDown(.LEFT_SUPER) ||
		rl.IsKeyDown(.RIGHT_SUPER) ||
		rl.IsKeyDown(.LEFT_CONTROL) ||
		rl.IsKeyDown(.RIGHT_CONTROL) \
	)
}

// Returns true if the mouse moved since the last frame.
// Used so keyboard arrow navigation in selection menus isn't overridden by a
// stationary cursor that happens to sit over an item. Mouse hover only changes
// the selection when the user is actively moving the mouse.
mouse_moved :: proc() -> bool {
	delta := rl.GetMouseDelta()
	return delta.x != 0 || delta.y != 0
}

// get_wheel_move returns this frame's mouse-wheel delta scaled by a
// platform multiplier so scroll speed feels consistent across OSes.
// Windows mouse wheels produce 1.0 per notch while macOS trackpads
// deliver larger inertia-driven values; the multiplier compensates.
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
// Resets the accumulator on direction reversal. Returns rows to scroll
// (positive = down the list).
wheel_row_steps :: proc(accum: ^f32) -> int {
	return wheel_accum_steps(accum, get_wheel_move())
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

// Word-jump left (skip trailing whitespace/newlines, then a run of non-space).
caret_word_left :: proc(s: string, pos: int) -> int {
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

caret_pixel_to_col_with :: proc(system: ^Text_System, line: string, px, font_size: i32) -> int {
	assert(system != nil, "caret_pixel_to_col_with: nil text system")
	assert(font_size > 0, "caret_pixel_to_col_with: invalid font size")
	if px <= 0 do return 0
	col := 0
	i := 0
	for i < len(line) {
		j := i + 1
		for j < len(line) && (line[j] & 0xC0) == 0x80 do j += 1
		prefix := strings.clone_to_cstring(line[:j], context.temp_allocator)
		width := measure_text_with(system, prefix, font_size)
		if width > px {
			previous := strings.clone_to_cstring(line[:i], context.temp_allocator)
			previous_width := measure_text_with(system, previous, font_size)
			if px - previous_width < width - px do return col
			return col + 1
		}
		col += 1
		i = j
	}
	return col
}

// Rune column within `line` closest to horizontal pixel `px` (relative to the
// line's left edge). Used for mouse click-to-place caret.
caret_pixel_to_col :: proc(line: string, px: i32) -> int {
	return caret_pixel_to_col_with(&default_text_system, line, px, FONT_SIZE)
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
		st.dragging = false
		return 0
	}
	max_off := total - visible
	off := clamp(offset, 0, max_off)

	style := ui_frame_theme(frame)
	rl.DrawRectangle(x, y, w, h, style.bg_secondary)
	thumb_h := max(ui_frame_sc(frame, 20), h * i32(visible) / i32(total))
	track_range := max(h - thumb_h, 1)
	thumb_y := y + i32(f32(track_range) * f32(off) / f32(max_off))

	mouse := rl.GetMousePosition()
	mouse = frame_to_local(frame, mouse)
	thumb_rect := rl.Rectangle{f32(x), f32(thumb_y), f32(w), f32(thumb_h)}
	track_rect := rl.Rectangle{f32(x), f32(y), f32(w), f32(h)}

	it := interact(frame, track_rect, &st.dragging)
	if it.pressed {
		if rl.CheckCollisionPointRec(mouse, thumb_rect) {
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
		it.hovered &&
		rl.CheckCollisionPointRec(mouse, rl.Rectangle{f32(x), f32(thumb_y), f32(w), f32(thumb_h)})
	col := style.border_color
	if st.dragging || thumb_hover do col = style.fg_accent
	rl.DrawRectangle(x, thumb_y, w, thumb_h, col)
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
color_mix :: proc(a, b: rl.Color, t: f32) -> rl.Color {
	assert(t >= 0 && t <= 1, "color_mix: t out of range")
	mix_u8 :: proc(x, y: u8, t: f32) -> u8 {
		return u8(clamp(f32(x) + (f32(y) - f32(x)) * t, 0, 255))
	}
	return rl.Color {
		mix_u8(a.r, b.r, t),
		mix_u8(a.g, b.g, t),
		mix_u8(a.b, b.b, t),
		mix_u8(a.a, b.a, t),
	}
}

// draw_shadow_rounded draws a soft drop shadow behind a rounded rect by
// stacking expanded translucent rings (gfx has no blur primitive). Draw it
// *before* the card fill so only the fringe remains visible. strength scales
// the theme.shadow_color alpha; 1.0 is the standard card shadow.
draw_shadow_rounded :: proc(rect: rl.Rectangle, roundness: f32, strength: f32 = 1.0) {
	assert(rect.width > 0 && rect.height > 0, "draw_shadow_rounded: empty rect")
	assert(strength >= 0 && strength <= 4, "draw_shadow_rounded: strength out of range")
	base := theme.shadow_color
	if base.a == 0 || strength == 0 do return
	// Fixed layer count: bounded work per call ("put a limit on everything").
	SHADOW_LAYERS :: 4
	alpha := clamp(f32(base.a) * strength / f32(SHADOW_LAYERS + 2), 0, 255)
	for i := SHADOW_LAYERS; i >= 1; i -= 1 {
		spread := f32(i) * 2
		layer := rl.Rectangle {
			rect.x - spread,
			rect.y - spread + 3, // bias downward for a lit-from-above look
			rect.width + spread * 2,
			rect.height + spread * 2,
		}
		rl.DrawRectangleRounded(
			layer,
			roundness,
			BTN_SEGMENTS,
			{base.r, base.g, base.b, u8(alpha)},
		)
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

hover_anim_frac :: proc(state: ^Button_State, hovered: bool) -> f32 {
	assert(state != nil, "hover_anim_frac: nil state")
	if theme.reduced_motion {
		state.hover = 1 if hovered else 0
		return state.hover
	}
	t := hover_anim_step(&state.hover, hovered, rl.GetFrameTime())
	target: f32 = 1 if hovered else 0
	if t != target do rl.RequestRedraw()
	assert(t >= 0 && t <= 1, "hover_anim_frac: fraction out of range")
	return t
}

// btn_palette returns the (rest, hovered) bg/fg/border colors for a style so
// btn can blend between them with the eased hover fraction.
@(private = "file")
btn_palette :: proc(theme: ^Theme, style: Btn_Style) -> (bg0, bg1, fg0, fg1, bd0, bd1: rl.Color) {
	assert(theme != nil, "btn_palette: nil theme")
	switch style {
	case .Primary:
		return theme.button_bg,
			theme.button_hover,
			theme.button_text,
			theme.button_text,
			theme.button_bg,
			theme.fg_accent
	case .Secondary:
		return theme.bg_active,
			theme.bg_hover,
			theme.fg_secondary,
			theme.fg_primary,
			rl.Color{},
			theme.fg_accent
	case .Danger:
		return theme.button_danger_bg,
			theme.button_danger_hover,
			theme.button_danger_fg,
			theme.button_danger_fg,
			rl.Color{},
			theme.fg_error
	case .Ghost:
		return rl.Color{}, theme.bg_hover, theme.fg_secondary, theme.fg_accent, rl.Color{}, rl.Color{}
	}
	return
}

// btn_gloss overlays a subtle top-half sheen on a button. The gradient quad
// is inset past the corner radius because scissor modes don't nest in gfx and
// a raw full-width quad would spill outside the rounded corners.
@(private = "file")
btn_gloss :: proc(theme: ^Theme, rect: rl.Rectangle) {
	assert(theme != nil, "btn_gloss: nil theme")
	top := theme.button_primary_grad_top
	if top.a == 0 do return
	radius := BTN_ROUNDNESS * min(rect.width, rect.height) * 0.5
	inset := i32(radius) + 1
	gw := i32(rect.width) - inset * 2
	if gw <= 0 do return
	rl.DrawRectangleGradientV(
		i32(rect.x) + inset,
		i32(rect.y) + 1,
		gw,
		i32(rect.height / 2),
		top,
		theme.button_primary_grad_bottom,
	)
}

// Unified button. Returns true if clicked this frame. Hover eases in/out via
// hover_anim_frac (frame-rate independent); pressed state darkens instantly.
// Pass `focus` to make the button keyboard-operable: clicking acquires the
// slot, the ring draws while focused, and Space/Enter activates.
btn :: proc {
	btn_at,
	btn_at_state,
	btn_ui,
	btn_ui_id,
	btn_ui_state,
	btn_ui_state_id,
}

// btn_ui sizes to its label (+padding) and auto-registers focus.
btn_ui :: proc(
	u: ^Ui,
	label: string,
	style: Btn_Style = .Secondary,
	enabled: bool = true,
) -> bool {
	label_c := strings.clone_to_cstring(label, context.temp_allocator)
	metrics := ui_frame_metrics(u.frame)
	w := measure_text_frame(u.frame, label_c, metrics.FONT_SIZE_LABEL) + metrics.PADDING * 2
	r := ui_slot(u, w, metrics.ROW_H_MD)
	fo := ui_focus(u) if enabled else Focus_Opt{}
	return btn_at(u.frame, r.x, r.y, r.w, r.h, label, style, enabled = enabled, focus = fo)
}

btn_ui_id :: proc(
	u: ^Ui,
	id: Focus_Id,
	label: string,
	style: Btn_Style = .Secondary,
	enabled: bool = true,
) -> bool {
	label_c := strings.clone_to_cstring(label, context.temp_allocator)
	metrics := ui_frame_metrics(u.frame)
	w := measure_text_frame(u.frame, label_c, metrics.FONT_SIZE_LABEL) + metrics.PADDING * 2
	r := ui_slot(u, w, metrics.ROW_H_MD)
	fo := ui_focus(u, id) if enabled else Focus_Opt{}
	return btn_at(u.frame, r.x, r.y, r.w, r.h, label, style, enabled = enabled, focus = fo)
}

btn_ui_state :: proc(
	u: ^Ui,
	state: ^Button_State,
	label: string,
	style: Btn_Style = .Secondary,
	enabled: bool = true,
) -> bool {
	assert(state != nil, "btn_ui_state: nil state")
	label_c := strings.clone_to_cstring(label, context.temp_allocator)
	metrics := ui_frame_metrics(u.frame)
	w := measure_text_frame(u.frame, label_c, metrics.FONT_SIZE_LABEL) + metrics.PADDING * 2
	r := ui_slot(u, w, metrics.ROW_H_MD)
	fo := ui_focus(u) if enabled else Focus_Opt{}
	return btn_at_state(
		u.frame,
		state,
		r.x,
		r.y,
		r.w,
		r.h,
		label,
		style,
		enabled = enabled,
		focus = fo,
	)
}

btn_ui_state_id :: proc(
	u: ^Ui,
	id: Focus_Id,
	state: ^Button_State,
	label: string,
	style: Btn_Style = .Secondary,
	enabled: bool = true,
) -> bool {
	assert(state != nil, "btn_ui_state_id: nil state")
	label_c := strings.clone_to_cstring(label, context.temp_allocator)
	metrics := ui_frame_metrics(u.frame)
	w := measure_text_frame(u.frame, label_c, metrics.FONT_SIZE_LABEL) + metrics.PADDING * 2
	r := ui_slot(u, w, metrics.ROW_H_MD)
	fo := ui_focus(u, id) if enabled else Focus_Opt{}
	return btn_at_state(
		u.frame,
		state,
		r.x,
		r.y,
		r.w,
		r.h,
		label,
		style,
		enabled = enabled,
		focus = fo,
	)
}

btn_at :: proc(
	frame: ^Ui_Frame,
	x, y, w, h: i32,
	label: string,
	style: Btn_Style = .Secondary,
	font_size: i32 = 0,
	enabled: bool = true,
	web_form_id: string = "",
	focus: Focus_Opt = {},
) -> bool {
	// Why assert: a nameless control is invisible to assistive tech.
	assert(label != "", "btn: empty accessible label")
	metrics := ui_frame_metrics(frame)
	fs := font_size if font_size > 0 else metrics.FONT_SIZE_LABEL
	style_theme := ui_frame_theme(frame)
	rect := rl.Rectangle{f32(x), f32(y), f32(w), f32(h)}
	it := interact(frame, rect)
	hovered := enabled && it.hovered
	clicked := enabled && it.clicked
	if enabled {
		focus_opt_click(frame, focus, x, y, w, h)
		clicked = clicked || focus_opt_activated(frame, focus)
	}
	if web_form_id != "" {
		clicked =
			clicked ||
			rl.SyncWebSubmitButton(web_form_id, label, x, y, w, h, i32(style), fs, enabled)
	}
	if hovered do request_cursor(frame, .POINTING_HAND)

	t: f32 = 1 if hovered else 0
	bg0, bg1, fg0, fg1, bd0, bd1 := btn_palette(style_theme, style)
	bg := color_mix(bg0, bg1, t)
	fg := color_mix(fg0, fg1, t)
	border := color_mix(bd0, bd1, t)
	// Pressed feedback while the mouse button is held over the button.
	if hovered && rl.IsMouseButtonDown(.LEFT) && (style == .Primary || style == .Secondary) {
		bg = style_theme.button_pressed
	}
	if !enabled {
		bg = style_theme.button_disabled_bg
		fg = style_theme.fg_muted_dim
		border = rl.Color{0, 0, 0, 0}
	}

	rl.DrawRectangleRounded(rect, BTN_ROUNDNESS, BTN_SEGMENTS, bg)
	if style == .Primary && enabled do btn_gloss(style_theme, rect)
	if border.a > 0 {
		rl.DrawRectangleRoundedLinesEx(rect, BTN_ROUNDNESS, BTN_SEGMENTS, BTN_BORDER_W, border)
	}
	if enabled && focus_opt_focused(focus) {
		draw_focus_ring(frame, x, y, w, h)
	}

	label_c := strings.clone_to_cstring(label, context.temp_allocator)
	text_w := measure_text_frame(frame, label_c, fs)
	draw_text_frame(frame, label_c, x + (w - text_w) / 2, y + (h - fs) / 2, fs, fg)

	sem: Sem_State
	if !enabled do sem += {.Disabled}
	semantic_push(frame, .Button, {x, y, w, h}, label, sem, focus)
	return clicked && enabled
}

btn_at_state :: proc(
	frame: ^Ui_Frame,
	state: ^Button_State,
	x, y, w, h: i32,
	label: string,
	style: Btn_Style = .Secondary,
	font_size: i32 = 0,
	enabled: bool = true,
	web_form_id: string = "",
	focus: Focus_Opt = {},
) -> bool {
	assert(state != nil, "btn_at_state: nil state")
	assert(label != "", "btn_at_state: empty accessible label")
	metrics := ui_frame_metrics(frame)
	fs := font_size if font_size > 0 else metrics.FONT_SIZE_LABEL
	style_theme := ui_frame_theme(frame)
	rect := rl.Rectangle{f32(x), f32(y), f32(w), f32(h)}
	it := interact(frame, rect)
	hovered := enabled && it.hovered
	clicked := enabled && it.clicked
	if enabled {
		focus_opt_click(frame, focus, x, y, w, h)
		clicked = clicked || focus_opt_activated(frame, focus)
	}
	if web_form_id != "" {
		clicked =
			clicked ||
			rl.SyncWebSubmitButton(web_form_id, label, x, y, w, h, i32(style), fs, enabled)
	}
	if hovered do request_cursor(frame, .POINTING_HAND)
	t := hover_anim_frac(state, hovered) if enabled else 0
	bg0, bg1, fg0, fg1, bd0, bd1 := btn_palette(style_theme, style)
	bg := color_mix(bg0, bg1, t)
	fg := color_mix(fg0, fg1, t)
	border := color_mix(bd0, bd1, t)
	if hovered && rl.IsMouseButtonDown(.LEFT) && (style == .Primary || style == .Secondary) {
		bg = theme.button_pressed
	}
	if !enabled {
		state.hover = 0
		bg = theme.button_disabled_bg
		fg = theme.fg_muted_dim
		border = rl.Color{0, 0, 0, 0}
	}
	rl.DrawRectangleRounded(rect, BTN_ROUNDNESS, BTN_SEGMENTS, bg)
	if style == .Primary && enabled do btn_gloss(style_theme, rect)
	if border.a > 0 {
		rl.DrawRectangleRoundedLinesEx(rect, BTN_ROUNDNESS, BTN_SEGMENTS, BTN_BORDER_W, border)
	}
	if enabled && focus_opt_focused(focus) do draw_focus_ring(frame, x, y, w, h)
	label_c := strings.clone_to_cstring(label, context.temp_allocator)
	text_w := measure_text_frame(frame, label_c, fs)
	draw_text_frame(frame, label_c, x + (w - text_w) / 2, y + (h - fs) / 2, fs, fg)
	sem: Sem_State
	if !enabled do sem += {.Disabled}
	semantic_push(frame, .Button, {x, y, w, h}, label, sem, focus)
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
	col := caret_pixel_to_col_with(ui_frame_text(frame), line, mouse_x - x, font_size)
	return lines[row].start + caret_col_to_byte(line, col)
}

hit_test_wrapped :: proc(
	x, y, max_width: i32,
	text: string,
	mouse_x, mouse_y: i32,
	font_size: i32 = FONT_SIZE,
) -> int {
	if len(text) == 0 do return -1
	lines := wrap_text(text, max_width, font_size)
	row := clamp(int((mouse_y - y) / LINE_HEIGHT), 0, len(lines) - 1)
	line := text[lines[row].start:lines[row].end]
	col := caret_pixel_to_col(line, mouse_x - x)
	return lines[row].start + caret_col_to_byte(line, col)
}

// Draw a single line with optional selection highlight behind it.
// Uses measure_text on actual substrings for pixel-accurate highlight positioning.
draw_line_with_selection :: proc(
	x, y: i32,
	line: string,
	font_size: i32,
	color: rl.Color,
	line_byte_start, sel_start, sel_end: int,
) {
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
		rl.DrawRectangle(hl_x, y, hl_w, i32(LINE_HEIGHT), theme.bg_selection)
	}

	line_c := strings.clone_to_cstring(line, context.temp_allocator)
	draw_text(line_c, x, y, font_size, color)
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

@(private = "file")
legacy_text_cull_top: i32 = min(i32)
@(private = "file")
legacy_text_cull_bottom: i32 = max(i32)

set_text_cull_band :: proc(top, bottom: i32) {
	legacy_text_cull_top = top
	legacy_text_cull_bottom = bottom
}

clear_text_cull_band :: proc() {
	legacy_text_cull_top = min(i32)
	legacy_text_cull_bottom = max(i32)
}

line_culled :: proc(y: i32) -> bool {
	return y + LINE_HEIGHT < legacy_text_cull_top || y > legacy_text_cull_bottom
}

draw_text_wrapped_frame :: proc(
	frame: ^Ui_Frame,
	x, y, max_width: i32,
	text: string,
	color: rl.Color,
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
			value := strings.clone_to_cstring(text[line.start:line.end], context.temp_allocator)
			draw_text_frame(frame, value, x, current_y, font_size, color)
		}
		current_y += line_height
	}
	return current_y - y
}

// Draw a scrollable text area with optional selection highlighting.
draw_text_wrapped :: proc(
	x, y, max_width: i32,
	text: string,
	color: rl.Color,
	font_size: i32 = FONT_SIZE,
	sel_start: int = -1,
	sel_end: int = -1,
	draw: bool = true,
) -> i32 {
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
			draw_line_with_selection(
				x,
				current_y,
				line,
				font_size,
				color,
				ln.start,
				sel_start,
				sel_end,
			)
		} else {
			line_c := strings.clone_to_cstring(line, context.temp_allocator)
			draw_text(line_c, x, current_y, font_size, color)
		}
		current_y += i32(LINE_HEIGHT)
	}

	return current_y - y
}

// Draw a single line of text, cutting it with an ellipsis if it would exceed
// max_width. Used for labels/paths in modals that must never overflow.
draw_text_truncated_frame :: proc(
	frame: ^Ui_Frame,
	text: string,
	x, y, max_width, font_size: i32,
	color: rl.Color,
) {
	assert(max_width >= 0 && font_size > 0, "draw_text_truncated_frame: invalid metrics")
	if len(text) == 0 do return
	out := truncate_to_width_frame(frame, text, max_width, font_size)
	out_c := strings.clone_to_cstring(out, context.temp_allocator)
	draw_text_frame(frame, out_c, x, y, font_size, color)
}

draw_text_truncated :: proc(text: string, x, y, max_width, font_size: i32, color: rl.Color) {
	if len(text) == 0 do return
	out := truncate_to_width(text, max_width, font_size)
	out_c := strings.clone_to_cstring(out, context.temp_allocator)
	draw_text(out_c, x, y, font_size, color)
}

// Draw a rounded "pill" badge with text. Returns the pill's full width so the
// caller can advance horizontally. Background and foreground are caller-chosen.
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

// Truncate_Side selects which side of the text an ellipsis replaces.
Truncate_Side :: enum u8 {
	Tail, // trailing ellipsis — keep the head visible
	Head, // leading ellipsis — keep the tail visible
}

// Return text truncated with an ellipsis on `side` so it fits max_width.
// The returned string is allocated in the temp allocator (or is the input
// unchanged when it already fits).
truncate_to_width_dir :: proc(
	text: string,
	max_width, font_size: i32,
	side: Truncate_Side,
) -> string {
	assert(max_width >= 0, "truncate_to_width_dir: negative width")
	assert(font_size > 0, "truncate_to_width_dir: non-positive font size")
	if len(text) == 0 do return text
	full_c := strings.clone_to_cstring(text, context.temp_allocator)
	if measure_text(full_c, font_size) <= max_width {
		return text
	}
	ell_c := strings.clone_to_cstring("…", context.temp_allocator)
	avail := max_width - measure_text(ell_c, font_size)
	if side == .Tail {
		// Walk runes forward accumulating width until we run out of room.
		end := 0
		for end < len(text) {
			next_i := end + 1
			for next_i < len(text) && (text[next_i] & 0xC0) == 0x80 do next_i += 1
			seg_c := strings.clone_to_cstring(text[:next_i], context.temp_allocator)
			if measure_text(seg_c, font_size) > avail do break
			end = next_i
		}
		return strings.concatenate({text[:end], "…"}, context.temp_allocator)
	}
	// Walk runes backward accumulating width until we run out of room.
	start := len(text)
	for start > 0 {
		prev := start - 1
		for prev > 0 && (text[prev] & 0xC0) == 0x80 do prev -= 1
		seg_c := strings.clone_to_cstring(text[prev:], context.temp_allocator)
		if measure_text(seg_c, font_size) > avail do break
		start = prev
	}
	return strings.concatenate({"…", text[start:]}, context.temp_allocator)
}

truncate_to_width_frame :: proc(
	frame: ^Ui_Frame,
	text: string,
	max_width, font_size: i32,
) -> string {
	assert(max_width >= 0, "truncate_to_width_frame: negative width")
	assert(font_size > 0, "truncate_to_width_frame: non-positive font size")
	if len(text) == 0 do return text
	full_c := strings.clone_to_cstring(text, context.temp_allocator)
	if measure_text_frame(frame, full_c, font_size) <= max_width do return text
	ell_c := strings.clone_to_cstring("…", context.temp_allocator)
	avail := max_width - measure_text_frame(frame, ell_c, font_size)
	end := 0
	for end < len(text) {
		next_i := end + 1
		for next_i < len(text) && (text[next_i] & 0xC0) == 0x80 do next_i += 1
		seg_c := strings.clone_to_cstring(text[:next_i], context.temp_allocator)
		if measure_text_frame(frame, seg_c, font_size) > avail do break
		end = next_i
	}
	return strings.concatenate({text[:end], "…"}, context.temp_allocator)
}

// Return text truncated with a trailing ellipsis so it fits within max_width.
truncate_to_width :: proc(text: string, max_width, font_size: i32) -> string {
	return truncate_to_width_dir(text, max_width, font_size, .Tail)
}

// Return text truncated with a LEADING ellipsis so the trailing portion (e.g.
// a file's name and extension) stays visible when it would overflow max_width.
truncate_to_width_left :: proc(text: string, max_width, font_size: i32) -> string {
	return truncate_to_width_dir(text, max_width, font_size, .Head)
}

// Return a path truncated in the MIDDLE so the first directory segment and the
// final segment (filename) stay visible when it would otherwise overflow
// max_width, e.g. "alloy/…/widgets.odin". A trailing '/' on directory entries
// is preserved. Allocated in the temp allocator.
truncate_path_middle :: proc(path: string, max_width, font_size: i32) -> string {
	if len(path) == 0 do return path
	full_c := strings.clone_to_cstring(path, context.temp_allocator)
	if measure_text(full_c, font_size) <= max_width {
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
		// No directory component — keep the tail of the bare name visible.
		return truncate_to_width_left(path, max_width, font_size)
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
	if measure_text(cand_c, font_size) <= max_width {
		return cand
	}

	// Candidate 2: …/last — drop the leading segment.
	cand2 := strings.concatenate({"…", sep, last_seg, trailing}, context.temp_allocator)
	cand2_c := strings.clone_to_cstring(cand2, context.temp_allocator)
	if measure_text(cand2_c, font_size) <= max_width {
		return cand2
	}

	// Candidate 3: even …/last is too wide — left-truncate the whole thing so
	// the filename's tail/extension stays visible.
	return truncate_to_width_left(path, max_width, font_size)
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

// ------------------------------------------------------------------
// ingot-only generic widgets (not present in the alloy superset).
// ------------------------------------------------------------------

spinner :: proc(cx, cy: i32, radius: f32, color: rl.Color = THEME_COLOR, segments: i32 = 24) {
	// The sentinel default resolves to the theme accent at call time
	// (defaults must be compile-time constants; the theme is runtime).
	color := color
	if color == THEME_COLOR do color = theme.fg_accent_light
	// Continuous animation: keep frames coming while a spinner is visible
	// (no-op in the default continuous frame strategy).
	rl.RequestRedraw()
	start := f32(math.mod(rl.GetTime() * 360.0, 360.0))
	thickness := max(radius * 0.28, 2.0)
	rl.DrawRing(
		rl.Vector2{f32(cx), f32(cy)},
		radius - thickness,
		radius,
		start,
		start + 270.0,
		segments,
		color,
	)
}

section_header :: proc(x, y, w: i32, label: string) -> i32 {
	lc := strings.clone_to_cstring(label, context.temp_allocator)
	draw_text(lc, x, y, FONT_SIZE_LABEL, theme.fg_label)
	rl.DrawRectangle(x, y + FONT_SIZE_LABEL + sc(5), w, 1, theme.border_subtle)
	return y + FONT_SIZE_LABEL + sc(11)
}

// status_pill draws a pill whose background is the fg color tinted to
// PILL_TINT_ALPHA. Returns the pill width.
status_pill :: proc(text: string, x, y, font_size: i32, color: rl.Color) -> i32 {
	return draw_pill(text, x, y, font_size, color, {color.r, color.g, color.b, PILL_TINT_ALPHA})
}

// progress_bar draws a rounded track + fill; frac clamped to [0,1].
progress_bar :: proc(x, y, w, h: i32, frac: f32, color: rl.Color) {
	track := rl.Rectangle{f32(x), f32(y), f32(w), f32(h)}
	rl.DrawRectangleRounded(track, 1.0, 4, theme.bg_active)
	fw := f32(w) * clamp(frac, 0, 1)
	if fw >= f32(h) { 	// avoid degenerate rounding on tiny fills
		rl.DrawRectangleRounded({f32(x), f32(y), fw, f32(h)}, 1.0, 4, color)
	} else if fw > 0 {
		rl.DrawRectangleRec({f32(x), f32(y), fw, f32(h)}, color)
	}
}

// eased moves current toward target at `speed` units per second (frame-rate
// independent exponential ease). Returns the updated value for convenience.
// Guaranteed to terminate: a step that makes no f32 progress (increment
// rounds to zero at large magnitudes) snaps to target, so "redraw until
// settled" callers can never spin forever.
eased :: proc(current: ^f32, target, dt, speed: f32) -> f32 {
	k := clamp(speed * dt, 0, 1)
	if k != k do k = 0 // NaN dt/speed: hold position rather than poison state
	prev := current^
	current^ += (target - current^) * k
	if abs(target - current^) < 0.001 do current^ = target
	if k > 0 && current^ == prev do current^ = target // f32 stall: settle now
	return current^
}

// progress_bar_animated draws a progress bar whose fill eases toward frac.
// `anim` is caller-owned eased state (reset it to 0 to replay the fill).
progress_bar_animated :: proc(x, y, w, h: i32, frac: f32, anim: ^f32, color: rl.Color) {
	eased(anim, clamp(frac, 0, 1), rl.GetFrameTime(), 10.0)
	if abs(clamp(frac, 0, 1) - anim^) >= 0.001 {
		// Still easing: keep frames coming until the fill settles.
		rl.RequestRedraw()
	}
	progress_bar(x, y, w, h, anim^, color)
}

// icon_btn draws a small square ghost button (for ✕ / ◀ / ▶ style glyphs).
// Returns true if clicked this frame.
icon_btn :: proc(
	frame: ^Ui_Frame,
	x, y, size: i32,
	label: string,
	enabled: bool = true,
	focus: Focus_Opt = {},
) -> bool {
	return btn_at(frame, x, y, size, size, label, .Ghost, FONT_SIZE_LABEL, enabled, focus = focus)
}

// kv_row draws key (left, truncated) and value (right-aligned) on one line.
kv_row :: proc(x, y, w: i32, key, value: string, key_col, val_col: rl.Color, font_size: i32 = 0) {
	fs := font_size if font_size > 0 else FONT_SIZE_LABEL
	vc := strings.clone_to_cstring(value, context.temp_allocator)
	vw := measure_text(vc, fs)
	draw_text(vc, x + w - vw, y, fs, val_col)
	draw_text_truncated(key, x, y, w - vw - sc(8), fs, key_col)
}

kv_row_frame :: proc(
	frame: ^Ui_Frame,
	x, y, w: i32,
	key, value: string,
	key_col, val_col: rl.Color,
	font_size: i32 = 0,
) {
	assert(frame != nil && frame.open, "kv_row_frame: invalid frame")
	fs := font_size if font_size > 0 else ui_frame_metrics(frame).FONT_SIZE_LABEL
	value_cstring := strings.clone_to_cstring(value, context.temp_allocator)
	value_width := measure_text_frame(frame, value_cstring, fs)
	draw_text_frame(frame, value_cstring, x + w - value_width, y, fs, val_col)
	draw_text_truncated_frame(
		frame,
		key,
		x,
		y,
		w - value_width - ui_frame_sc(frame, 8),
		fs,
		key_col,
	)
}

// list_row_bg draws the unified rounded row background for hover/selection.
list_row_bg :: proc(rect: rl.Rectangle, selected, hovered: bool) {
	if selected {
		rl.DrawRectangleRounded(rect, 0.25, 4, theme.bg_active)
	} else if hovered {
		rl.DrawRectangleRounded(rect, 0.25, 4, theme.bg_hover)
	}
}

// --- scroll pane -----------------------------------------------------------

// Pane is caller-owned state for a scissored, wheel-scrollable region with a
// measured content height (clamps scroll on the next frame) and a scrollbar.
Pane :: struct {
	scroll:    f32,
	content_h: i32, // measured by pane_end, consumed next frame
	open:      bool, // set by pane_begin, cleared by pane_end (balance check)
	sbar:      Scrollbar_State, // per-pane scrollbar drag state
}

pane_reset :: proc(p: ^Pane) {
	p.scroll = 0
	p.content_h = 0
	p.open = false
}

// pane_begin handles wheel input over the pane rect, clamps scroll, begins the
// scissor, and returns the y cursor the caller should start drawing at. When
// `keyboard` is true and the mouse hovers the pane, PageUp/PageDown/Home/End
// and Up/Down arrows scroll it — leave it off for panes that host text inputs
// (their caret owns those keys).
pane_begin :: proc(
	frame: ^Ui_Frame,
	p: ^Pane,
	x, y, w, h: i32,
	pad: i32 = 10,
	keyboard: bool = false,
) -> (
	cursor_y: i32,
) {
	// Why assert: an already-open pane means a missing pane_end — the scissor
	// stack would corrupt every subsequent draw.
	assert(!p.open, "pane_begin: pane already begun (missing pane_end)")
	assert(w >= 0 && h >= 0, "pane_begin: negative pane size")
	p.open = true
	mouse := rl.GetMousePosition()
	hovered :=
		rl.CheckCollisionPointRec(mouse, {f32(x), f32(y), f32(w), f32(h)}) &&
		!route_occluded(frame, mouse)
	if hovered {
		p.scroll -= get_wheel_move() * f32(sc(24))
	}
	if keyboard && hovered {
		pane_keyboard_scroll(p, h)
	}
	p.scroll = clamp(p.scroll, 0, f32(max(p.content_h - h, 0)))
	begin_pane_scissor(frame, x, y, w, h)
	return y + sc(pad) - i32(p.scroll)
}

// pane_keyboard_scroll applies PageUp/PageDown/Home/End and Up/Down arrow
// scrolling to a hovered pane. Scroll is clamped by pane_begin right after.
@(private = "file")
pane_keyboard_scroll :: proc(p: ^Pane, h: i32) {
	assert(p != nil, "pane_keyboard_scroll: nil pane")
	assert(p.open, "pane_keyboard_scroll: pane not begun")
	step := f32(LINE_HEIGHT)
	if rl.IsKeyPressed(.DOWN) || rl.IsKeyPressedRepeat(.DOWN) do p.scroll += step
	if rl.IsKeyPressed(.UP) || rl.IsKeyPressedRepeat(.UP) do p.scroll -= step
	if rl.IsKeyPressed(.PAGE_DOWN) || rl.IsKeyPressedRepeat(.PAGE_DOWN) do p.scroll += f32(h)
	if rl.IsKeyPressed(.PAGE_UP) || rl.IsKeyPressedRepeat(.PAGE_UP) do p.scroll -= f32(h)
	if rl.IsKeyPressed(.HOME) do p.scroll = 0
	if rl.IsKeyPressed(.END) do p.scroll = f32(max(p.content_h - h, 0))
}

// pane_end ends the scissor, records the measured content height from the
// caller's final y cursor, and draws/handles the scrollbar when content
// overflows the pane.
pane_end :: proc(frame: ^Ui_Frame, p: ^Pane, x, y, w, h: i32, end_y: i32, pad: i32 = 10) {
	// Why assert: pane_end without pane_begin would pop a scissor the pane
	// never pushed, clipping unrelated draws.
	assert(p.open, "pane_end: pane not begun")
	assert(h >= 0, "pane_end: negative pane height")
	p.open = false
	rl.EndScissorMode()
	start_y := y + sc(pad) - i32(p.scroll)
	p.content_h = end_y - start_y + sc(pad)
	if p.content_h > h {
		off := scrollbar_ex(
			frame,
			&p.sbar,
			x + w - sc(9),
			y + sc(2),
			sc(5),
			h - sc(4),
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
back_btn_w :: proc(label: string) -> i32 {
	txt := fmt.ctprintf("\u2190 %s", label)
	return measure_text(txt, FONT_SIZE_LABEL) + sc(14)
}

// back_btn draws the standard Ghost-style "← label" navigation button.
// Returns true if clicked this frame.
back_btn :: proc(frame: ^Ui_Frame, x, y: i32, label: string, focus: Focus_Opt = {}) -> bool {
	txt := fmt.tprintf("\u2190 %s", label)
	return btn_at(frame, x, y, back_btn_w(label), sc(22), txt, .Ghost, focus = focus)
}

// --- standardized collapsible section header -------------------------------

// collapsible_header draws a full-width clickable header band with the label
// on the left and a chevron state indicator on the right. Toggles open^ on
// click (or Space/Enter while focused); returns true on the frame it toggled
// (caller persists open state).
collapsible_header :: proc(
	frame: ^Ui_Frame,
	x, y, w: i32,
	label: string,
	open: ^bool,
	font_size: i32 = FONT_SIZE_LABEL,
	focus: Focus_Opt = {},
) -> (
	toggled: bool,
) {
	assert(open != nil, "collapsible_header: nil open state")
	assert(w > 0, "collapsible_header: non-positive width")
	h := sc(26)
	rect := rl.Rectangle{f32(x), f32(y), f32(w), f32(h)}
	it := interact(frame, rect)
	hovered := it.hovered
	focus_opt_click(frame, focus, x, y, w, h)
	if hovered {
		request_cursor(frame, .POINTING_HAND)
	}
	if it.clicked {
		open^ = !open^
		toggled = true
	}
	if focus_opt_activated(frame, focus) {
		open^ = !open^
		toggled = true
	}
	if focus_opt_focused(focus) {
		draw_focus_ring(frame, x, y, w, h)
	}
	lbl := strings.clone_to_cstring(label, context.temp_allocator)
	draw_text(lbl, x + sc(10), y + sc(6), font_size, theme.fg_label)
	ind: cstring = "\u25BE" if open^ else "\u25B8"
	iw := measure_text(ind, font_size)
	draw_text(
		ind,
		x + w - iw - sc(10),
		y + sc(6),
		font_size,
		theme.fg_primary if hovered else theme.fg_secondary,
	)
	return
}

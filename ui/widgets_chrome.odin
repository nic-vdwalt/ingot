// LIB-CANDIDATE: imports only core:*.
// Widgets take plain data and return events; callers own all state.
// Merged from openalloy/alloy (superset input/undo/pill/split features)
// plus ingot-only generic widgets (spinner, panes, back_btn, etc.).
package ui

import "core:math"

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
		frame_text_center_y(frame, y, metrics.PANEL_HEADER_H, metrics.FONT_SIZE_LABEL),
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
// Windows and Linux (GLFW) mouse wheels produce 1.0 per notch while macOS

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


// --- standardized collapsible section header -------------------------------

Collapsible_Header_Options :: struct {
	icon:        rune,
	right_label: string,
	font_size:   i32,
	height:      i32,
	focus:       Focus_Opt,
	field_id:    string,
	widget:      Widget_Id,
	motion:      ^Control_Motion_State,
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
	culled := rect_culled_frame(frame, {x, y, w, height})
	channel: ^Transition_F32_State
	if options.motion != nil do channel = &options.motion.value
	_ = control_motion_fraction(
		frame,
		channel,
		1 if open^ || interaction.hovered else 0,
		snap = culled,
	)
	if !culled {
		if focus_opt_focused(options.focus) do draw_focus_ring(frame, x, y, w, height)

		pad := ui_frame_sc(frame, 10)
		text_y := frame_text_center_y(frame, y, height, font_size)
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

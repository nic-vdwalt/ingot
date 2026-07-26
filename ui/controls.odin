// LIB-CANDIDATE: imports only core:*.
// Core form controls: checkbox, radio button, slider. Immediate mode with
// caller-owned value state, Rect_I32 geometry, theme-driven colors, and
// optional keyboard focus (Focus_Opt) with Space/Enter/arrow operation.
package ui

import "core:math"
import "core:strings"


// checkbox draws a check control with a label. Toggles checked^ on click or
// Space/Enter while focused. Returns true on the frame the value changed.
checkbox :: proc {
	checkbox_at,
	checkbox_ui,
	checkbox_ui_id,
}

// checkbox_ui carves its own slot (content-sized) and auto-registers focus.
checkbox_ui :: proc(u: ^Ui, label: string, checked: ^bool) -> (changed: bool) {
	metrics := ui_frame_metrics(u.frame)
	label_c := strings.clone_to_cstring(label, context.temp_allocator)
	w :=
		metrics.CONTROL_BOX +
		metrics.CONTROL_GAP +
		measure_text_frame(u.frame, label_c, metrics.FONT_SIZE_BODY)
	r := ui_slot(u, w, metrics.ROW_H_SM)
	fo := ui_focus(u) if ui_slot_visible(r) else Focus_Opt{}
	return checkbox_at(u.frame, r, label, checked, fo)
}

checkbox_ui_id :: proc(u: ^Ui, id: Focus_Id, label: string, checked: ^bool) -> (changed: bool) {
	metrics := ui_frame_metrics(u.frame)
	label_c := strings.clone_to_cstring(label, context.temp_allocator)
	w :=
		metrics.CONTROL_BOX +
		metrics.CONTROL_GAP +
		measure_text_frame(u.frame, label_c, metrics.FONT_SIZE_BODY)
	r := ui_slot(u, w, metrics.ROW_H_SM)
	fo := ui_focus(u, id) if ui_slot_visible(r) else Focus_Opt{}
	return checkbox_at(u.frame, r, label, checked, fo)
}

checkbox_at :: proc(
	frame: ^Ui_Frame,
	rect: Rect_I32,
	label: string,
	checked: ^bool,
	focus: Focus_Opt = {},
) -> (
	changed: bool,
) {
	assert(checked != nil, "checkbox: nil checked state")
	if ui_frame_drop_degenerate(frame, rect.w <= 0 || rect.h <= 0) do return false
	// Why assert: a nameless control is invisible to assistive tech.
	assert(label != "", "checkbox: empty accessible label")
	rrect := Rectangle{f32(rect.x), f32(rect.y), f32(rect.w), f32(rect.h)}
	it := interact(frame, rrect)
	hovered := it.hovered
	focus_opt_click(frame, focus, rect.x, rect.y, rect.w, rect.h)
	if hovered do request_cursor(frame, .POINTING_HAND)
	if it.clicked || focus_opt_activated(frame, focus) {
		checked^ = !checked^
		changed = true
	}

	metrics := ui_frame_metrics(frame)
	style := ui_frame_theme(frame)
	box := metrics.CONTROL_BOX
	bx := rect.x
	by := rect.y + (rect.h - box) / 2
	box_rect := Rectangle{f32(bx), f32(by), f32(box), f32(box)}
	bg := style.button_bg if checked^ else style.bg_input
	border := style.fg_accent if hovered || focus_opt_focused(focus) else style.border_color
	draw_rectangle_rounded(frame, box_rect, 0.25, 4, bg)
	draw_rectangle_rounded_lines_ex(frame, box_rect, 0.25, 4, 1.0, border)
	if checked^ {
		// Check mark: two strokes proportional to the box size.
		cx := f32(bx)
		cy := f32(by)
		s := f32(box)
		draw_line_ex(
			frame,
			{cx + s * 0.22, cy + s * 0.52},
			{cx + s * 0.44, cy + s * 0.74},
			2.0,
			style.button_text,
		)
		draw_line_ex(
			frame,
			{cx + s * 0.44, cy + s * 0.74},
			{cx + s * 0.80, cy + s * 0.28},
			2.0,
			style.button_text,
		)
	}
	if focus_opt_focused(focus) {
		draw_focus_ring(frame, bx, by, box, box)
	}
	label_c := strings.clone_to_cstring(label, context.temp_allocator)
	draw_text_frame(
		frame,
		label_c,
		bx + box + metrics.CONTROL_GAP,
		rect.y + (rect.h - metrics.FONT_SIZE_BODY) / 2,
		metrics.FONT_SIZE_BODY,
		style.fg_primary,
	)
	sem: Sem_State
	if checked^ do sem += {.Checked}
	semantic_push(frame, .Checkbox, rect, label, sem, focus)
	return changed
}

// radio draws one exclusive-choice row. Selecting it stores `value` into
// selected^. Returns true on the frame the selection changed to this value.
radio :: proc {
	radio_at,
	radio_ui,
	radio_ui_id,
}

// radio_ui carves its own slot (content-sized) and auto-registers focus.
radio_ui :: proc(u: ^Ui, label: string, selected: ^i32, value: i32) -> (changed: bool) {
	metrics := ui_frame_metrics(u.frame)
	label_c := strings.clone_to_cstring(label, context.temp_allocator)
	w :=
		metrics.CONTROL_BOX +
		metrics.CONTROL_GAP +
		measure_text_frame(u.frame, label_c, metrics.FONT_SIZE_BODY)
	r := ui_slot(u, w, metrics.ROW_H_SM)
	fo := ui_focus(u) if ui_slot_visible(r) else Focus_Opt{}
	return radio_at(u.frame, r, label, selected, value, fo)
}

radio_ui_id :: proc(
	u: ^Ui,
	id: Focus_Id,
	label: string,
	selected: ^i32,
	value: i32,
) -> (
	changed: bool,
) {
	metrics := ui_frame_metrics(u.frame)
	label_c := strings.clone_to_cstring(label, context.temp_allocator)
	w :=
		metrics.CONTROL_BOX +
		metrics.CONTROL_GAP +
		measure_text_frame(u.frame, label_c, metrics.FONT_SIZE_BODY)
	r := ui_slot(u, w, metrics.ROW_H_SM)
	fo := ui_focus(u, id) if ui_slot_visible(r) else Focus_Opt{}
	return radio_at(u.frame, r, label, selected, value, fo)
}

radio_at :: proc(
	frame: ^Ui_Frame,
	rect: Rect_I32,
	label: string,
	selected: ^i32,
	value: i32,
	focus: Focus_Opt = {},
) -> (
	changed: bool,
) {
	assert(selected != nil, "radio: nil selected state")
	if ui_frame_drop_degenerate(frame, rect.w <= 0 || rect.h <= 0) do return false
	// Why assert: a nameless control is invisible to assistive tech.
	assert(label != "", "radio: empty accessible label")
	rrect := Rectangle{f32(rect.x), f32(rect.y), f32(rect.w), f32(rect.h)}
	it := interact(frame, rrect)
	hovered := it.hovered
	focus_opt_click(frame, focus, rect.x, rect.y, rect.w, rect.h)
	if hovered do request_cursor(frame, .POINTING_HAND)
	if (it.clicked || focus_opt_activated(frame, focus)) && selected^ != value {
		selected^ = value
		changed = true
	}

	metrics := ui_frame_metrics(frame)
	style := ui_frame_theme(frame)
	box := metrics.CONTROL_BOX
	r := f32(box) / 2
	ccx := f32(rect.x) + r
	ccy := f32(rect.y) + f32(rect.h) / 2
	is_on := selected^ == value
	border :=
		style.fg_accent if hovered || focus_opt_focused(focus) || is_on else style.border_color
	draw_circle_v(frame, {ccx, ccy}, r, style.bg_input)
	draw_circle_lines_v(frame, {ccx, ccy}, r, border)
	if is_on {
		draw_circle_v(frame, {ccx, ccy}, r * 0.45, style.fg_accent)
	}
	if focus_opt_focused(focus) {
		draw_focus_ring(frame, rect.x, rect.y + (rect.h - box) / 2, box, box)
	}
	label_c := strings.clone_to_cstring(label, context.temp_allocator)
	draw_text_frame(
		frame,
		label_c,
		rect.x + box + metrics.CONTROL_GAP,
		rect.y + (rect.h - metrics.FONT_SIZE_BODY) / 2,
		metrics.FONT_SIZE_BODY,
		style.fg_primary,
	)
	sem: Sem_State
	if is_on do sem += {.Checked}
	semantic_push(frame, .Radio, rect, label, sem, focus)
	return changed
}

// slider_step_value maps a 0..1 track ratio to a value in [lo, hi], snapped
// to `step` (0 = continuous). Pure; used by slider and its tests.
slider_step_value :: proc(lo, hi, step, t: f32) -> f32 {
	assert(hi > lo, "slider_step_value: hi must exceed lo")
	assert(t >= 0 && t <= 1, "slider_step_value: ratio out of range")
	v := lo + (hi - lo) * t
	if step > 0 {
		v = lo + math.round((v - lo) / step) * step
	}
	return clamp(v, lo, hi)
}

// slider_keyboard_delta returns the increment for one arrow-key press:
// `step` when set, else 1% of the range.
slider_keyboard_delta :: proc(lo, hi, step: f32) -> f32 {
	assert(hi > lo, "slider_keyboard_delta: hi must exceed lo")
	d := step if step > 0 else (hi - lo) / 100.0
	assert(d > 0, "slider_keyboard_delta: non-positive delta")
	return d
}

Slider_State :: struct {
	dragging: bool,
}

// slider draws a horizontal slider over [lo, hi] with optional stepping.
// Dragging or clicking the track moves the value; Left/Right adjust it while
// focused. Returns true on the frame the value changed.
slider :: proc {
	slider_at,
	slider_at_state,
	slider_ui,
	slider_ui_id,
	slider_ui_state,
	slider_ui_state_id,
}

@(private = "file")
slider_ui_slot :: proc(u: ^Ui, width: i32) -> Rect_I32 {
	assert(u != nil && u.frame != nil, "slider_ui_slot: invalid UI")
	metrics := ui_frame_metrics(u.frame)
	resolved_width := width if width > 0 else metrics.MENU_MIN_W + metrics.CONTROL_BOX * 4
	assert(resolved_width > 0, "slider_ui_slot: invalid width")
	return ui_slot(u, resolved_width, metrics.ROW_H_SM)
}

// slider_ui carves its own slot (width w, 0 = sensible default) and
// auto-registers focus.
slider_ui :: proc(
	u: ^Ui,
	value: ^f32,
	lo, hi: f32,
	step: f32 = 0,
	w: i32 = 0,
	a11y_label: string = "",
) -> (
	changed: bool,
) {
	assert(a11y_label != "", "slider_ui: empty accessible label")
	r := slider_ui_slot(u, w)
	fo := ui_focus(u) if ui_slot_visible(r) else Focus_Opt{}
	return slider_at(u.frame, r, value, lo, hi, step, fo, a11y_label)
}

slider_ui_id :: proc(
	u: ^Ui,
	id: Focus_Id,
	value: ^f32,
	lo, hi: f32,
	step: f32 = 0,
	w: i32 = 0,
	a11y_label: string = "",
) -> (
	changed: bool,
) {
	assert(a11y_label != "", "slider_ui_id: empty accessible label")
	r := slider_ui_slot(u, w)
	fo := ui_focus(u, id) if ui_slot_visible(r) else Focus_Opt{}
	return slider_at(u.frame, r, value, lo, hi, step, fo, a11y_label)
}

slider_ui_state :: proc(
	u: ^Ui,
	state: ^Slider_State,
	value: ^f32,
	lo, hi: f32,
	step: f32 = 0,
	w: i32 = 0,
	a11y_label: string = "",
) -> bool {
	assert(state != nil, "slider_ui_state: nil state")
	assert(a11y_label != "", "slider_ui_state: empty accessible label")
	r := slider_ui_slot(u, w)
	fo := ui_focus(u) if ui_slot_visible(r) else Focus_Opt{}
	return slider_at_state(u.frame, state, r, value, lo, hi, step, fo, a11y_label)
}

slider_ui_state_id :: proc(
	u: ^Ui,
	id: Focus_Id,
	state: ^Slider_State,
	value: ^f32,
	lo, hi: f32,
	step: f32 = 0,
	w: i32 = 0,
	a11y_label: string = "",
) -> bool {
	assert(state != nil, "slider_ui_state_id: nil state")
	assert(a11y_label != "", "slider_ui_state_id: empty accessible label")
	r := slider_ui_slot(u, w)
	fo := ui_focus(u, id) if ui_slot_visible(r) else Focus_Opt{}
	return slider_at_state(u.frame, state, r, value, lo, hi, step, fo, a11y_label)
}

slider_at :: proc(
	frame: ^Ui_Frame,
	rect: Rect_I32,
	value: ^f32,
	lo, hi: f32,
	step: f32 = 0,
	focus: Focus_Opt = {},
	a11y_label: string = "",
) -> (
	changed: bool,
) {
	assert(value != nil, "slider: nil value")
	if ui_frame_drop_degenerate(frame, hi <= lo || rect.w <= 0 || rect.h <= 0) do return false
	old := value^
	rrect := Rectangle{f32(rect.x), f32(rect.y), f32(rect.w), f32(rect.h)}
	mouse := get_mouse_position(frame)
	it := interact(frame, rrect)
	hovered := it.hovered
	focus_opt_click(frame, focus, rect.x, rect.y, rect.w, rect.h)
	if hovered do request_cursor(frame, .POINTING_HAND)

	metrics := ui_frame_metrics(frame)
	style := ui_frame_theme(frame)
	knob_r := metrics.SLIDER_KNOB_R
	track_x := f32(rect.x) + knob_r
	track_w := f32(rect.w) - knob_r * 2
	if track_w < 1 do track_w = 1

	if it.pressed {
		t := clamp((mouse.x - track_x) / track_w, 0, 1)
		value^ = slider_step_value(lo, hi, step, t)
	}
	if focus_opt_focused(focus) {
		d := slider_keyboard_delta(lo, hi, step)
		if is_key_pressed(frame, .LEFT) || is_key_pressed_repeat(frame, .LEFT) {
			value^ = clamp(value^ - d, lo, hi)
		}
		if is_key_pressed(frame, .RIGHT) || is_key_pressed_repeat(frame, .RIGHT) {
			value^ = clamp(value^ + d, lo, hi)
		}
	}
	value^ = clamp(value^, lo, hi)

	// Track + fill + knob.
	cy := f32(rect.y) + f32(rect.h) / 2
	th := f32(metrics.SLIDER_TRACK_H)
	draw_rectangle_rounded(frame, {track_x, cy - th / 2, track_w, th}, 1.0, 4, style.bg_active)
	frac := (value^ - lo) / (hi - lo)
	fill_w := track_w * frac
	if fill_w > 0 {
		draw_rectangle_rounded(frame, {track_x, cy - th / 2, fill_w, th}, 1.0, 4, style.fg_accent)
	}
	knob_x := track_x + track_w * frac
	knob_col := style.fg_accent if hovered || focus_opt_focused(focus) else style.fg_secondary
	draw_circle_v(frame, {knob_x, cy}, knob_r, style.bg_input)
	draw_circle_lines_v(frame, {knob_x, cy}, knob_r, knob_col)
	draw_circle_v(frame, {knob_x, cy}, knob_r * 0.55, knob_col)
	if focus_opt_focused(focus) {
		draw_focus_ring(frame, rect.x, rect.y, rect.w, rect.h)
	}
	semantic_push(frame, .Slider, rect, a11y_label, {}, focus, value = value^, lo = lo, hi = hi)
	return value^ != old
}

slider_at_state :: proc(
	frame: ^Ui_Frame,
	state: ^Slider_State,
	rect: Rect_I32,
	value: ^f32,
	lo, hi: f32,
	step: f32 = 0,
	focus: Focus_Opt = {},
	a11y_label: string = "",
) -> bool {
	assert(state != nil && value != nil, "slider_at_state: nil state or value")
	if ui_frame_drop_degenerate(frame, hi <= lo || rect.w <= 0 || rect.h <= 0) do return false
	old := value^
	rrect := Rectangle{f32(rect.x), f32(rect.y), f32(rect.w), f32(rect.h)}
	mouse := get_mouse_position(frame)
	it := interact(frame, rrect, &state.dragging)
	focus_opt_click(frame, focus, rect.x, rect.y, rect.w, rect.h)
	if it.hovered do request_cursor(frame, .POINTING_HAND)
	metrics := ui_frame_metrics(frame)
	style := ui_frame_theme(frame)
	knob_r := metrics.SLIDER_KNOB_R
	track_x := f32(rect.x) + knob_r
	track_w := max(f32(rect.w) - knob_r * 2, 1)
	if it.held {
		t := clamp((mouse.x - track_x) / track_w, 0, 1)
		value^ = slider_step_value(lo, hi, step, t)
	}
	if focus_opt_focused(focus) {
		d := slider_keyboard_delta(lo, hi, step)
		if is_key_pressed(frame, .LEFT) || is_key_pressed_repeat(frame, .LEFT) {
			value^ = clamp(value^ - d, lo, hi)
		}
		if is_key_pressed(frame, .RIGHT) || is_key_pressed_repeat(frame, .RIGHT) {
			value^ = clamp(value^ + d, lo, hi)
		}
	}
	value^ = clamp(value^, lo, hi)
	cy := f32(rect.y) + f32(rect.h) / 2
	th := f32(metrics.SLIDER_TRACK_H)
	draw_rectangle_rounded(frame, {track_x, cy - th / 2, track_w, th}, 1.0, 4, style.bg_active)
	frac := (value^ - lo) / (hi - lo)
	fill_w := track_w * frac
	if fill_w > 0 {
		draw_rectangle_rounded(
			frame,
			{track_x, cy - th / 2, fill_w, th},
			1.0,
			4,
			style.fg_accent,
		)
	}
	knob_x := track_x + track_w * frac
	active := it.hovered || state.dragging || focus_opt_focused(focus)
	knob_col := style.fg_accent if active else style.fg_secondary
	draw_circle_v(frame, {knob_x, cy}, knob_r, style.bg_input)
	draw_circle_lines_v(frame, {knob_x, cy}, knob_r, knob_col)
	draw_circle_v(frame, {knob_x, cy}, knob_r * 0.55, knob_col)
	if focus_opt_focused(focus) do draw_focus_ring(frame, rect.x, rect.y, rect.w, rect.h)
	semantic_push(frame, .Slider, rect, a11y_label, {}, focus, value = value^, lo = lo, hi = hi)
	return value^ != old
}

// LIB-CANDIDATE: imports only core:* and ingot:gfx.
// Core form controls: checkbox, radio button, slider. Immediate mode with
// caller-owned value state, Rect_I32 geometry, theme-driven colors, and
// optional keyboard focus (Focus_Opt) with Space/Enter/arrow operation.
package ui

import "core:math"
import "core:strings"
import rl "ingot:gfx"

// checkbox draws a check control with a label. Toggles checked^ on click or
// Space/Enter while focused. Returns true on the frame the value changed.
checkbox :: proc {
	checkbox_at,
	checkbox_ui,
	checkbox_ui_id,
}

// checkbox_ui carves its own slot (content-sized) and auto-registers focus.
checkbox_ui :: proc(u: ^Ui, label: string, checked: ^bool) -> (changed: bool) {
	label_c := strings.clone_to_cstring(label, context.temp_allocator)
	w := CONTROL_BOX + CONTROL_GAP + measure_text(label_c, FONT_SIZE_BODY)
	r := ui_slot(u, w, ROW_H_SM)
	return checkbox_at(r, label, checked, ui_focus(u))
}

checkbox_ui_id :: proc(u: ^Ui, id: Focus_Id, label: string, checked: ^bool) -> (changed: bool) {
	label_c := strings.clone_to_cstring(label, context.temp_allocator)
	w := CONTROL_BOX + CONTROL_GAP + measure_text(label_c, FONT_SIZE_BODY)
	r := ui_slot(u, w, ROW_H_SM)
	return checkbox_at(r, label, checked, ui_focus(u, id))
}

checkbox_at :: proc(
	rect: Rect_I32,
	label: string,
	checked: ^bool,
	focus: Focus_Opt = {},
) -> (
	changed: bool,
) {
	assert(checked != nil, "checkbox: nil checked state")
	assert(rect.w > 0 && rect.h > 0, "checkbox: empty rect")
	// Why assert: a nameless control is invisible to assistive tech.
	assert(label != "", "checkbox: empty accessible label")
	rrect := rl.Rectangle{f32(rect.x), f32(rect.y), f32(rect.w), f32(rect.h)}
	it := interact(rrect)
	hovered := it.hovered
	focus_opt_click(focus, rect.x, rect.y, rect.w, rect.h)
	if hovered do request_cursor(.POINTING_HAND)
	if it.clicked || focus_opt_activated(focus) {
		checked^ = !checked^
		changed = true
	}

	box := CONTROL_BOX
	bx := rect.x
	by := rect.y + (rect.h - box) / 2
	box_rect := rl.Rectangle{f32(bx), f32(by), f32(box), f32(box)}
	bg := theme.button_bg if checked^ else theme.bg_input
	border := theme.fg_accent if hovered || focus_opt_focused(focus) else theme.border_color
	rl.DrawRectangleRounded(box_rect, 0.25, 4, bg)
	rl.DrawRectangleRoundedLinesEx(box_rect, 0.25, 4, 1.0, border)
	if checked^ {
		// Check mark: two strokes proportional to the box size.
		cx := f32(bx)
		cy := f32(by)
		s := f32(box)
		rl.DrawLineEx(
			{cx + s * 0.22, cy + s * 0.52},
			{cx + s * 0.44, cy + s * 0.74},
			2.0,
			theme.button_text,
		)
		rl.DrawLineEx(
			{cx + s * 0.44, cy + s * 0.74},
			{cx + s * 0.80, cy + s * 0.28},
			2.0,
			theme.button_text,
		)
	}
	if focus_opt_focused(focus) {
		draw_focus_ring(bx, by, box, box)
	}
	label_c := strings.clone_to_cstring(label, context.temp_allocator)
	draw_text(
		label_c,
		bx + box + CONTROL_GAP,
		rect.y + (rect.h - FONT_SIZE_BODY) / 2,
		FONT_SIZE_BODY,
		theme.fg_primary,
	)
	sem: Sem_State
	if checked^ do sem += {.Checked}
	semantic_push(.Checkbox, rect, label, sem, focus)
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
	label_c := strings.clone_to_cstring(label, context.temp_allocator)
	w := CONTROL_BOX + CONTROL_GAP + measure_text(label_c, FONT_SIZE_BODY)
	r := ui_slot(u, w, ROW_H_SM)
	return radio_at(r, label, selected, value, ui_focus(u))
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
	label_c := strings.clone_to_cstring(label, context.temp_allocator)
	w := CONTROL_BOX + CONTROL_GAP + measure_text(label_c, FONT_SIZE_BODY)
	r := ui_slot(u, w, ROW_H_SM)
	return radio_at(r, label, selected, value, ui_focus(u, id))
}

radio_at :: proc(
	rect: Rect_I32,
	label: string,
	selected: ^i32,
	value: i32,
	focus: Focus_Opt = {},
) -> (
	changed: bool,
) {
	assert(selected != nil, "radio: nil selected state")
	assert(rect.w > 0 && rect.h > 0, "radio: empty rect")
	// Why assert: a nameless control is invisible to assistive tech.
	assert(label != "", "radio: empty accessible label")
	rrect := rl.Rectangle{f32(rect.x), f32(rect.y), f32(rect.w), f32(rect.h)}
	it := interact(rrect)
	hovered := it.hovered
	focus_opt_click(focus, rect.x, rect.y, rect.w, rect.h)
	if hovered do request_cursor(.POINTING_HAND)
	if (it.clicked || focus_opt_activated(focus)) && selected^ != value {
		selected^ = value
		changed = true
	}

	box := CONTROL_BOX
	r := f32(box) / 2
	ccx := f32(rect.x) + r
	ccy := f32(rect.y) + f32(rect.h) / 2
	is_on := selected^ == value
	border :=
		theme.fg_accent if hovered || focus_opt_focused(focus) || is_on else theme.border_color
	rl.DrawCircleV({ccx, ccy}, r, theme.bg_input)
	rl.DrawCircleLinesV({ccx, ccy}, r, border)
	if is_on {
		rl.DrawCircleV({ccx, ccy}, r * 0.45, theme.fg_accent)
	}
	if focus_opt_focused(focus) {
		draw_focus_ring(rect.x, rect.y + (rect.h - box) / 2, box, box)
	}
	label_c := strings.clone_to_cstring(label, context.temp_allocator)
	draw_text(
		label_c,
		rect.x + box + CONTROL_GAP,
		rect.y + (rect.h - FONT_SIZE_BODY) / 2,
		FONT_SIZE_BODY,
		theme.fg_primary,
	)
	sem: Sem_State
	if is_on do sem += {.Checked}
	semantic_push(.Radio, rect, label, sem, focus)
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

// The slider currently being dragged, keyed by its value pointer so multiple
// sliders never fight over one drag (only one mouse exists).
@(private = "file")
slider_active: ^f32

// slider draws a horizontal slider over [lo, hi] with optional stepping.
// Dragging or clicking the track moves the value; Left/Right adjust it while
// focused. Returns true on the frame the value changed.
slider :: proc {
	slider_at,
	slider_ui,
	slider_ui_id,
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
	ww := w if w > 0 else MENU_MIN_W + CONTROL_BOX * 4
	r := ui_slot(u, ww, ROW_H_SM)
	return slider_at(r, value, lo, hi, step, ui_focus(u), a11y_label)
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
	ww := w if w > 0 else MENU_MIN_W + CONTROL_BOX * 4
	r := ui_slot(u, ww, ROW_H_SM)
	return slider_at(r, value, lo, hi, step, ui_focus(u, id), a11y_label)
}

slider_at :: proc(
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
	assert(hi > lo, "slider: hi must exceed lo")
	assert(rect.w > 0 && rect.h > 0, "slider: empty rect")
	old := value^
	rrect := rl.Rectangle{f32(rect.x), f32(rect.y), f32(rect.w), f32(rect.h)}
	mouse := rl.GetMousePosition()
	it := interact(rrect)
	hovered := it.hovered
	focus_opt_click(focus, rect.x, rect.y, rect.w, rect.h)
	if hovered do request_cursor(.POINTING_HAND)

	knob_r := SLIDER_KNOB_R
	track_x := f32(rect.x) + knob_r
	track_w := f32(rect.w) - knob_r * 2
	if track_w < 1 do track_w = 1

	if it.pressed {
		slider_active = value
	}
	if slider_active == value {
		if rl.IsMouseButtonDown(.LEFT) {
			t := clamp((mouse.x - track_x) / track_w, 0, 1)
			value^ = slider_step_value(lo, hi, step, t)
		} else {
			slider_active = nil
		}
	}
	if focus_opt_focused(focus) {
		d := slider_keyboard_delta(lo, hi, step)
		if rl.IsKeyPressed(.LEFT) || rl.IsKeyPressedRepeat(.LEFT) do value^ = clamp(value^ - d, lo, hi)
		if rl.IsKeyPressed(.RIGHT) || rl.IsKeyPressedRepeat(.RIGHT) do value^ = clamp(value^ + d, lo, hi)
	}
	value^ = clamp(value^, lo, hi)

	// Track + fill + knob.
	cy := f32(rect.y) + f32(rect.h) / 2
	th := f32(SLIDER_TRACK_H)
	rl.DrawRectangleRounded({track_x, cy - th / 2, track_w, th}, 1.0, 4, theme.bg_active)
	frac := (value^ - lo) / (hi - lo)
	fill_w := track_w * frac
	if fill_w > 0 {
		rl.DrawRectangleRounded({track_x, cy - th / 2, fill_w, th}, 1.0, 4, theme.fg_accent)
	}
	knob_x := track_x + track_w * frac
	knob_col :=
		theme.fg_accent if hovered || slider_active == value || focus_opt_focused(focus) else theme.fg_secondary
	rl.DrawCircleV({knob_x, cy}, knob_r, theme.bg_input)
	rl.DrawCircleLinesV({knob_x, cy}, knob_r, knob_col)
	rl.DrawCircleV({knob_x, cy}, knob_r * 0.55, knob_col)
	if focus_opt_focused(focus) {
		draw_focus_ring(rect.x, rect.y, rect.w, rect.h)
	}
	semantic_push(.Slider, rect, a11y_label, {}, focus, value = value^, lo = lo, hi = hi)
	return value^ != old
}

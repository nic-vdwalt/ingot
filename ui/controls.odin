// LIB-CANDIDATE: imports only core:*.
// Core form controls: checkbox, radio button, slider. Immediate mode with
// caller-owned value state, Rect_I32 geometry, theme-driven colors, and
// optional keyboard focus (Focus_Opt) with Space/Enter/arrow operation.
package ui

import "core:math"
import "core:strings"


// checkbox draws a check control with a label. Toggles checked^ on click or
// Space/Enter while focused. Returns true on the frame the value changed.
// checkbox carves its own content-sized slot; checkbox_at takes an explicit rect.
@(private = "package")
checkbox_id :: proc(u: ^Ui, id: Widget_Id, label: string, checked: ^bool) -> (changed: bool) {
	assert(u != nil && u.open, "checkbox: frame not open")
	assert(id != WIDGET_ID_NONE, "checkbox: zero stable id")
	assert(checked != nil, "checkbox: nil checked")
	metrics := ui_frame_metrics(u.frame)
	w := control_row_width(u.frame, label, 0)
	r := slot_next_px(u, w, metrics.ROW_H_SM)
	fo := focus(u, id) if slot_visible(r) else Focus_Opt{}
	return checkbox_at(u.frame, r, label, checked, fo, id)
}

@(private = "package")
checkbox_string :: proc(u: ^Ui, key, label: string, checked: ^bool) -> bool {
	return checkbox_id(u, id(u, key), label, checked)
}

@(private = "package")
checkbox_u64 :: proc(u: ^Ui, key: u64, label: string, checked: ^bool) -> bool {
	return checkbox_id(u, id(u, key), label, checked)
}

checkbox :: proc {
	checkbox_id,
	checkbox_string,
	checkbox_u64,
}

// control_label_size resolves the size a checkbox/radio label is drawn at.
// Zero means "use the default", matching how btn_at resolves its font_size.
// Measurement and drawing both go through here so an auto-layout row can never
// be sized for one font and painted in another.
//
// The default is FONT_SIZE_LABEL, the same size btn_at defaults to. Controls
// and buttons sit next to each other in every real panel; while they disagreed
// by default, every such panel was inconsistent unless the caller intervened.
@(private = "file")
control_label_size :: proc(frame: ^Ui_Frame, font_size: i32) -> i32 {
	assert(frame != nil, "control_label_size: nil frame")
	assert(font_size >= 0, "control_label_size: negative font size")
	if font_size > 0 do return font_size
	size := ui_frame_metrics(frame).FONT_SIZE_LABEL
	assert(size > 0, "control_label_size: invalid metric")
	return size
}

// control_row_width measures box + gap + label for the content-sized wrappers.
@(private = "file")
control_row_width :: proc(frame: ^Ui_Frame, label: string, font_size: i32) -> i32 {
	assert(frame != nil, "control_row_width: nil frame")
	metrics := ui_frame_metrics(frame)
	label_c := strings.clone_to_cstring(label, context.temp_allocator)
	width :=
		metrics.CONTROL_BOX +
		metrics.CONTROL_GAP +
		measure_text_frame(frame, label_c, control_label_size(frame, font_size))
	assert(width > 0, "control_row_width: invalid width")
	return width
}

checkbox_at :: proc(
	frame: ^Ui_Frame,
	rect: Rect_I32,
	label: string,
	checked: ^bool,
	focus: Focus_Opt = {},
	widget: Widget_Id = WIDGET_ID_NONE,
	font_size: i32 = 0,
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
	// Radius and segments come from the token layer so the checkbox rounds to
	// the same curve as the button beside it; the 0.25 literal this replaces
	// was a fixed ratio that drifted from every other corner in the tree.
	box_round := radius_ratio(frame, .SM, box_rect)
	box_segments := radius_segments(radius_pixels(frame, .SM, f32(box)))
	draw_rectangle_rounded(frame, box_rect, box_round, box_segments, bg)
	draw_rectangle_rounded_lines_ex(
		frame,
		box_rect,
		box_round,
		box_segments,
		border_pixels(frame, .Hairline),
		border,
	)
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
	label_x := bx + box + metrics.CONTROL_GAP
	fs := control_label_size(frame, font_size)
	// Why truncate: the label must stay inside the caller's rect; a fixed-width
	// panel would otherwise spill body text over whatever is painted behind it.
	draw_text_truncated_frame(
		frame,
		label,
		label_x,
		rect.y + (rect.h - fs) / 2,
		max(rect.x + rect.w - label_x, 0),
		fs,
		style.fg_primary,
	)
	sem: Sem_State
	if checked^ do sem += {.Checked}
	semantic_push(frame, .Checkbox, rect, label, sem, focus, widget = widget)
	return changed
}

// radio draws one exclusive-choice row. Selecting it stores `value` into
// selected^. Returns true on the frame the selection changed to this value.
// radio carves its own content-sized slot; radio_at takes an explicit rect.
@(private = "package")
radio_id :: proc(
	u: ^Ui,
	id: Widget_Id,
	label: string,
	selected: ^i32,
	value: i32,
) -> (
	changed: bool,
) {
	assert(u != nil && u.open, "radio: frame not open")
	assert(id != WIDGET_ID_NONE, "radio: zero stable id")
	assert(selected != nil, "radio: nil selected")
	metrics := ui_frame_metrics(u.frame)
	w := control_row_width(u.frame, label, 0)
	r := slot_next_px(u, w, metrics.ROW_H_SM)
	fo := focus(u, id) if slot_visible(r) else Focus_Opt{}
	return radio_at(u.frame, r, label, selected, value, fo, id)
}

@(private = "package")
radio_string :: proc(u: ^Ui, key, label: string, selected: ^i32, value: i32) -> bool {
	return radio_id(u, id(u, key), label, selected, value)
}

@(private = "package")
radio_u64 :: proc(u: ^Ui, key: u64, label: string, selected: ^i32, value: i32) -> bool {
	return radio_id(u, id(u, key), label, selected, value)
}

radio :: proc {
	radio_id,
	radio_string,
	radio_u64,
}

radio_at :: proc(
	frame: ^Ui_Frame,
	rect: Rect_I32,
	label: string,
	selected: ^i32,
	value: i32,
	focus: Focus_Opt = {},
	widget: Widget_Id = WIDGET_ID_NONE,
	font_size: i32 = 0,
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
	label_x := rect.x + box + metrics.CONTROL_GAP
	fs := control_label_size(frame, font_size)
	// Why truncate: mirrors checkbox_at - the label never escapes its own rect.
	draw_text_truncated_frame(
		frame,
		label,
		label_x,
		rect.y + (rect.h - fs) / 2,
		max(rect.x + rect.w - label_x, 0),
		fs,
		style.fg_primary,
	)
	sem: Sem_State
	if is_on do sem += {.Checked}
	semantic_push(frame, .Radio, rect, label, sem, focus, widget = widget)
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
// slider carves its own slot (width 0 = sensible default); slider_at takes an
// explicit rect. slider_state / slider_at_state add drag-animation state.
slider :: proc(
	u: ^Ui,
	id: Widget_Id,
	value: ^f32,
	lo, hi: f32,
	step: f32 = 0,
	width: i32 = 0,
	a11y_label: string = "",
) -> (
	changed: bool,
) {
	assert(u != nil && u.open, "slider: frame not open")
	assert(id != WIDGET_ID_NONE, "slider: zero stable id")
	assert(a11y_label != "", "slider: empty accessible label")
	r := slider_slot_px(u, width)
	fo := focus(u, id) if slot_visible(r) else Focus_Opt{}
	return slider_at(u.frame, r, value, lo, hi, step, fo, a11y_label, id)
}

@(private = "file")
slider_slot_px :: proc(u: ^Ui, width: i32) -> Rect_I32 {
	assert(u != nil && u.frame != nil, "slider_slot_px: invalid UI")
	metrics := ui_frame_metrics(u.frame)
	resolved_width :=
		ui_frame_sc(u.frame, width) if width > 0 else metrics.MENU_MIN_W + metrics.CONTROL_BOX * 4
	assert(resolved_width > 0, "slider_slot_px: invalid width")
	return slot_next_px(u, resolved_width, metrics.ROW_H_SM)
}

// slider_state is slider plus caller-owned knob animation state.
slider_state :: proc(
	u: ^Ui,
	id: Widget_Id,
	state: ^Slider_State,
	value: ^f32,
	lo, hi: f32,
	step: f32 = 0,
	w: i32 = 0,
	a11y_label: string = "",
) -> bool {
	assert(u != nil && u.open, "slider_state: frame not open")
	assert(id != WIDGET_ID_NONE, "slider_state: zero stable id")
	assert(state != nil, "slider_state: nil state")
	assert(a11y_label != "", "slider_state: empty accessible label")
	r := slider_slot_px(u, w)
	fo := focus(u, id) if slot_visible(r) else Focus_Opt{}
	return slider_at_state(u.frame, state, r, value, lo, hi, step, fo, a11y_label, id)
}

slider_at :: proc(
	frame: ^Ui_Frame,
	rect: Rect_I32,
	value: ^f32,
	lo, hi: f32,
	step: f32 = 0,
	focus: Focus_Opt = {},
	a11y_label: string = "",
	widget: Widget_Id = WIDGET_ID_NONE,
) -> (
	changed: bool,
) {
	assert(value != nil, "slider: nil value")
	if ui_frame_drop_degenerate(frame, hi <= lo || rect.w <= 0 || rect.h <= 0) do return false
	rrect := Rectangle{f32(rect.x), f32(rect.y), f32(rect.w), f32(rect.h)}
	mouse := frame_to_local(frame, get_mouse_position(frame))
	press := frame_to_local(frame, frame.interaction.press_pos)
	dragging :=
		is_mouse_button_down(frame, .LEFT) &&
		frame.interaction.press_seen &&
		point_in_rect(press, rrect)
	it := interact(frame, rrect)
	hovered := it.hovered
	focus_opt_click(frame, focus, rect.x, rect.y, rect.w, rect.h)
	if hovered do request_cursor(frame, .POINTING_HAND)
	return slider_resolve_and_paint(
		frame,
		rect,
		value,
		lo,
		hi,
		step,
		focus,
		a11y_label,
		widget,
		it.pressed || dragging,
		mouse.x,
		hovered || focus_opt_focused(focus),
	)
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
	widget: Widget_Id = WIDGET_ID_NONE,
) -> bool {
	assert(state != nil && value != nil, "slider_at_state: nil state or value")
	if ui_frame_drop_degenerate(frame, hi <= lo || rect.w <= 0 || rect.h <= 0) do return false
	rrect := Rectangle{f32(rect.x), f32(rect.y), f32(rect.w), f32(rect.h)}
	mouse := frame_to_local(frame, get_mouse_position(frame))
	it := interact(frame, rrect, &state.dragging)
	focus_opt_click(frame, focus, rect.x, rect.y, rect.w, rect.h)
	if it.hovered do request_cursor(frame, .POINTING_HAND)
	return slider_resolve_and_paint(
		frame,
		rect,
		value,
		lo,
		hi,
		step,
		focus,
		a11y_label,
		widget,
		it.held,
		mouse.x,
		it.hovered || state.dragging || focus_opt_focused(focus),
	)
}

// slider_resolve_and_paint is the shared tail of slider_at and
// slider_at_state: pointer/keyboard value resolution, clamping, painting, the
// focus ring, and the semantic node. The two entry points differ only in how
// they source interaction (press-rect drag vs caller-owned drag state), so
// they compute apply_pointer and knob_active and delegate everything else.
@(private = "file")
slider_resolve_and_paint :: proc(
	frame: ^Ui_Frame,
	rect: Rect_I32,
	value: ^f32,
	lo, hi, step: f32,
	focus: Focus_Opt,
	a11y_label: string,
	widget: Widget_Id,
	apply_pointer: bool,
	mouse_x: f32,
	knob_active: bool,
) -> (
	changed: bool,
) {
	assert(value != nil, "slider_resolve_and_paint: nil value")
	old := value^
	metrics := ui_frame_metrics(frame)
	style := ui_frame_theme(frame)
	knob_r := metrics.SLIDER_KNOB_R
	track_x := f32(rect.x) + knob_r
	track_w := max(f32(rect.w) - knob_r * 2, 1)

	if apply_pointer {
		t := clamp((mouse_x - track_x) / track_w, 0, 1)
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
	draw_rounded_fill(frame, {track_x, cy - th / 2, track_w, th}, .Pill, style.bg_active)
	frac := (value^ - lo) / (hi - lo)
	fill_w := track_w * frac
	if fill_w > 0 {
		draw_rounded_fill(frame, {track_x, cy - th / 2, fill_w, th}, .Pill, style.fg_accent)
	}
	knob_x := track_x + track_w * frac
	knob_col := style.fg_accent if knob_active else style.fg_secondary
	draw_circle_v(frame, {knob_x, cy}, knob_r, style.bg_input)
	draw_circle_lines_v(frame, {knob_x, cy}, knob_r, knob_col)
	draw_circle_v(frame, {knob_x, cy}, knob_r * 0.55, knob_col)
	if focus_opt_focused(focus) {
		draw_focus_ring(frame, rect.x, rect.y, rect.w, rect.h)
	}
	semantic_push(
		frame,
		.Slider,
		rect,
		a11y_label,
		{},
		focus,
		value = value^,
		lo = lo,
		hi = hi,
		widget = widget,
	)
	return value^ != old
}

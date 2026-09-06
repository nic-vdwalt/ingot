#+build !js
package ui

import "core:testing"

@(test)
geometry_tokens_follow_mid_frame_scale_change :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	frame: Ui_Frame
	ui_frame_begin(&frame, &runtime)
	defer ui_frame_end(&frame)
	before_radius := radius_pixels(&frame, .MD, 100)
	before_border := border_pixels(&frame, .Emphasis)
	ui_runtime_set_scale(&runtime, 2)
	testing.expect_value(t, radius_pixels(&frame, .MD, 100), before_radius * 2)
	testing.expect_value(t, border_pixels(&frame, .Emphasis), before_border * 2)
}

@(test)
toggle_spec_measures_and_emits_checked_semantics :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	backend: Test_Text_Backend_State
	ui_runtime_set_text_backend(
		&runtime,
		{data = &backend, font_for_size = test_text_font_for_size, measure = test_text_measure},
	)
	sem_enable(&runtime, true)
	output := new(Ui_Output)
	defer free(output)
	frame: Ui_Frame
	frame.output = output
	ui_frame_begin(&frame, &runtime)
	defer ui_frame_end(&frame)
	u: Ui
	begin(&u, &frame, {0, 0, 200, 40})
	defer end(&u)
	checked := true
	spec := Toggle_Spec {
		id      = Widget_Id(7),
		label   = "Enabled",
		checked = &checked,
	}
	size := toggle_spec_size(&u, spec)
	testing.expect(t, size.w > size.h && size.h > 0)
	_ = toggle_spec_at(&u, spec, {0, 0, size.w, size.h})
	testing.expect_value(t, frame.semantics.cur.count, 1)
	testing.expect_value(t, frame.semantics.cur.nodes[0].role, Sem_Role.Checkbox)
	testing.expect(t, .Checked in frame.semantics.cur.nodes[0].state)
}

@(test)
slider_step_value_snaps_and_clamps :: proc(t: ^testing.T) {
	// Continuous (step 0): straight lerp.
	testing.expect_value(t, slider_step_value(0, 10, 0, 0.5), f32(5))
	testing.expect_value(t, slider_step_value(0, 10, 0, 0), f32(0))
	testing.expect_value(t, slider_step_value(0, 10, 0, 1), f32(10))
	// Stepped: snaps to the nearest multiple of step from lo.
	testing.expect_value(t, slider_step_value(0, 10, 2, 0.4), f32(4))
	testing.expect_value(t, slider_step_value(0, 10, 2, 0.61), f32(6))
	// Negative ranges work.
	testing.expect_value(t, slider_step_value(-5, 5, 5, 0.5), f32(0))
	// Snapping never escapes [lo, hi].
	testing.expect_value(t, slider_step_value(0, 10, 3, 1), f32(9))
}

@(test)
slider_keyboard_delta_prefers_step :: proc(t: ^testing.T) {
	testing.expect_value(t, slider_keyboard_delta(0, 10, 2), f32(2))
	// No step: 1% of the range.
	testing.expect_value(t, slider_keyboard_delta(0, 100, 0), f32(1))
}

@(private = "file")
slider_test_input :: proc(
	mouse: Vec2,
	pressed := false,
	released := false,
	down := false,
) -> Ui_Input {
	input: Ui_Input
	input.mouse_position = mouse
	index := input_mouse_index(.LEFT)
	assert(index >= 0, "slider_test_input: invalid mouse button")
	input.mouse_pressed[index] = pressed
	input.mouse_released[index] = released
	input.mouse_down[index] = down
	return input
}

@(test)
slider_pointer_mapping_uses_pane_local_coordinates :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	output := new(Ui_Output)
	defer free(output)
	frame: Ui_Frame
	defer ui_frame_destroy(&frame)
	frame.output = output
	rect := Rect_I32{20, 10, 200, 24}
	origin := Vector2{100, 50}
	knob_r := runtime.metrics.SLIDER_KNOB_R
	track_x := origin.x + f32(rect.x) + knob_r
	track_w := f32(rect.w) - knob_r * 2
	x_positions := [3]f32{track_x, track_x + track_w / 2, track_x + track_w}
	want_values := [3]f32{0, 5, 10}

	for index in 0 ..< len(x_positions) {
		value: f32 = -1
		mouse := Vector2{x_positions[index], origin.y + f32(rect.y) + 1}
		input := slider_test_input(mouse, pressed = true, down = true)
		ui_frame_begin(&frame, &runtime, &input)
		ui_frame_pane_push(&frame, origin)
		changed := slider_at(&frame, rect, &value, 0, 10)
		ui_frame_pane_pop(&frame)
		ui_frame_end(&frame)
		testing.expect(t, changed, "translated slider press did not change value")
		testing.expect_value(t, value, want_values[index])
	}
}

@(test)
slider_state_drag_uses_pane_local_coordinates :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	output := new(Ui_Output)
	defer free(output)
	frame: Ui_Frame
	defer ui_frame_destroy(&frame)
	frame.output = output
	state: Slider_State
	value: f32 = 0
	rect := Rect_I32{20, 10, 200, 24}
	origin := Vector2{100, 50}
	knob_r := runtime.metrics.SLIDER_KNOB_R
	track_x := origin.x + f32(rect.x) + knob_r
	track_w := f32(rect.w) - knob_r * 2
	mouse_y := origin.y + f32(rect.y) + 1

	input := slider_test_input({track_x, mouse_y}, pressed = true, down = true)
	ui_frame_begin(&frame, &runtime, &input)
	ui_frame_pane_push(&frame, origin)
	_ = slider_at_state(&frame, &state, rect, &value, 0, 10)
	ui_frame_pane_pop(&frame)
	ui_frame_end(&frame)
	testing.expect(t, state.dragging, "translated slider did not begin dragging")
	testing.expect_value(t, value, f32(0))

	input = slider_test_input({track_x + track_w / 2, mouse_y}, down = true)
	ui_frame_begin(&frame, &runtime, &input)
	ui_frame_pane_push(&frame, origin)
	changed := slider_at_state(&frame, &state, rect, &value, 0, 10)
	ui_frame_pane_pop(&frame)
	ui_frame_end(&frame)
	testing.expect(t, changed, "translated slider drag did not change value")
	testing.expect_value(t, value, f32(5))

	input = slider_test_input({track_x + track_w, mouse_y}, released = true)
	ui_frame_begin(&frame, &runtime, &input)
	ui_frame_pane_push(&frame, origin)
	_ = slider_at_state(&frame, &state, rect, &value, 0, 10)
	ui_frame_pane_pop(&frame)
	ui_frame_end(&frame)
	testing.expect(t, !state.dragging, "translated slider remained latched after release")
}

@(test)
menu_nav_skips_separators_and_disabled :: proc(t: ^testing.T) {
	items := []Menu_Item {
		{label = "a"},
		{separator = true},
		{label = "b", disabled = true},
		{label = "c"},
	}
	// Down from "a" skips the separator and the disabled row to reach "c".
	testing.expect_value(t, menu_nav_next(items, 0, 1), 3)
	// Down from "c" wraps back to "a".
	testing.expect_value(t, menu_nav_next(items, 3, 1), 0)
	// Up from "a" wraps to "c".
	testing.expect_value(t, menu_nav_next(items, 0, -1), 3)
}

@(test)
menu_nav_all_unselectable_stays_put :: proc(t: ^testing.T) {
	items := []Menu_Item{{separator = true}, {label = "x", disabled = true}}
	testing.expect_value(t, menu_nav_next(items, 1, 1), 1)
}

@(test)
context_menu_height_counts_rows :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	frame: Ui_Frame
	ui_frame_begin(&frame, &runtime)
	defer ui_frame_end(&frame)
	items := []Menu_Item{{label = "a"}, {separator = true}, {label = "b"}}
	want := runtime.metrics.MENU_PAD * 2 + runtime.metrics.MENU_ITEM_H * 2 + ui_frame_sc(&frame, 5)
	testing.expect_value(t, context_menu_height_frame(&frame, items), want)
}

@(private = "file")
containment_advance :: proc(text: cstring, size: i32) -> i32 {
	return i32(len(string(text))) * 8
}

@(test)
checkbox_and_radio_labels_stay_inside_their_rect :: proc(t: ^testing.T) {
	// A caller-sized row (e.g. a fixed-width map overlay panel) must never let
	// a long label paint past its own rect and onto whatever is behind it.
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	state := Test_Text_Backend_State {
		advance = 8,
	}
	ui_runtime_set_text_backend(
		&runtime,
		{data = &state, font_for_size = test_text_font_for_size, measure = test_text_measure},
	)
	// Truncation measures through the Text_System, drawing through the text
	// backend. Give both the same fixed advance: with the default estimator
	// (len * size / 2) the two disagree, and this test would only pass at the
	// font size that happened to make them agree.
	set_measure_backend_with(&runtime.text, containment_advance)
	output := new(Ui_Output)
	defer free(output)
	frame: Ui_Frame
	frame.output = output
	ui_frame_begin(&frame, &runtime)
	rect := Rect_I32{0, 0, 120, 22}
	checked := false
	selected: i32 = 0
	_ = checkbox_at(&frame, rect, "Municipality screening", &checked)
	_ = radio_at(&frame, {rect.x, 40, rect.w, rect.h}, "Municipality screening", &selected, 0)
	ui_frame_end(&frame)

	labels := 0
	for index in 0 ..< output.main.count {
		command := output.main.commands[index]
		if command.kind != .Text do continue
		labels += 1
		drawn := paint_text(&output.main, command)
		width := f32(len(drawn)) * state.advance
		testing.expect(t, len(drawn) < len("Municipality screening"), "label was not truncated")
		testing.expect(
			t,
			command.p0.x + width <= f32(rect.x + rect.w),
			"label paints past its rect",
		)
	}
	testing.expect_value(t, labels, 2)
}

// Characterization: control labels default to the same size buttons use, so a
// panel mixing a checkbox with a button is consistent without either call site
// naming a size. Callers may still override per control.
@(test)
control_labels_default_to_button_label_size :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	state := Test_Text_Backend_State {
		advance = 8,
	}
	ui_runtime_set_text_backend(
		&runtime,
		{data = &state, font_for_size = test_text_font_for_size, measure = test_text_measure},
	)
	output := new(Ui_Output)
	defer free(output)
	frame: Ui_Frame
	frame.output = output
	ui_frame_begin(&frame, &runtime)
	metrics := ui_frame_metrics(&frame)
	rect := Rect_I32{0, 0, 400, 22}
	checked := false
	selected: i32 = 0
	override := metrics.FONT_SIZE_NOTE
	_ = checkbox_at(&frame, rect, "Base map", &checked)
	_ = radio_at(&frame, {rect.x, 40, rect.w, rect.h}, "Base map", &selected, 0)
	_ = checkbox_at(&frame, {rect.x, 80, rect.w, rect.h}, "Base map", &checked, {}, 0, override)
	_ = radio_at(&frame, {rect.x, 120, rect.w, rect.h}, "Base map", &selected, 0, {}, 0, override)
	ui_frame_end(&frame)

	sizes: [dynamic]f32
	defer delete(sizes)
	for index in 0 ..< output.main.count {
		command := output.main.commands[index]
		if command.kind != .Text do continue
		append(&sizes, command.font_size)
	}
	testing.expect_value(t, len(sizes), 4)
	testing.expect_value(t, sizes[0], f32(metrics.FONT_SIZE_LABEL))
	testing.expect_value(t, sizes[1], f32(metrics.FONT_SIZE_LABEL))
	testing.expect_value(t, sizes[2], f32(override))
	testing.expect_value(t, sizes[3], f32(override))
}

@(test)
theme_palettes_define_widget_colors :: proc(t: ^testing.T) {
	// Every color the new widgets rely on must be present in both built-in
	// palettes; a zero-alpha entry renders the control invisible.
	for pal in ([2]Theme{theme_dark(), theme_light()}) {
		testing.expect(t, pal.focus_ring.a > 0, "focus_ring unset")
		testing.expect(t, pal.modal_dim.a > 0, "modal_dim unset")
		testing.expect(t, pal.bg_popup.a > 0, "bg_popup unset")
		testing.expect(t, pal.button_danger_bg.a > 0, "button_danger_bg unset")
		testing.expect(t, pal.button_danger_hover.a > 0, "button_danger_hover unset")
		testing.expect(t, pal.button_danger_fg.a > 0, "button_danger_fg unset")
		testing.expect(t, pal.button_pressed.a > 0, "button_pressed unset")
		testing.expect(t, pal.button_disabled_bg.a > 0, "button_disabled_bg unset")
	}
}

#+build !js
package ui

import "core:testing"

// The facade wrappers exist to guarantee three properties for every widget:
// the slot comes from the layout in logical units, focus registers only when
// that slot is visible, and a collapsed root never paints. These tests pin
// those properties rather than each widget's pixels, which the *_at tier
// already covers.

@(private = "file")
facade_widget_frame :: proc(
	runtime: ^Ui_Runtime,
	frame: ^Ui_Frame,
	output: ^Ui_Output,
	text_backend: ^Test_Text_Backend_State,
	scale: f32 = 1,
) {
	assert(runtime != nil && frame != nil, "facade_widget_frame: nil argument")
	assert(output != nil && text_backend != nil, "facade_widget_frame: nil argument")
	assert(scale > 0, "facade_widget_frame: non-positive scale")
	ui_runtime_init(runtime)
	ui_runtime_set_scale(runtime, scale)
	ui_runtime_set_text_backend(
		runtime,
		{
			data = text_backend,
			font_for_size = test_text_font_for_size,
			measure = test_text_measure,
		},
	)
	// A real output buffer and text backend: these widgets paint, and a
	// missing sink would abort inside the paint layer before the focus
	// assertions ran.
	frame.output = output
	ui_frame_begin(frame, runtime)
}

@(test)
facade_widgets_register_focus_once_each :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	frame: Ui_Frame
	output := new(Ui_Output)
	defer free(output)
	text_backend: Test_Text_Backend_State
	facade_widget_frame(&runtime, &frame, output, &text_backend)
	defer ui_runtime_destroy(&runtime)
	defer ui_frame_end(&frame)

	u: Ui
	open := true
	begin(&u, &frame, {0, 0, 400, 400})
	scope_begin(&u, "panel")
	_ = collapsible_header(&u, id(&u, "details"), "Details", &open)
	_ = icon_btn(&u, id(&u, "close"), "\u2715")
	_ = back_btn(&u, id(&u, "back"), "Home")
	scope_end(&u)
	end(&u)

	// Three interactive widgets, three traversal entries, no duplicates.
	testing.expect_value(t, u.stable_count, 3)
	testing.expect_value(t, u.focus_count, 0)
}

@(test)
presentational_facade_widgets_register_no_focus :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	frame: Ui_Frame
	output := new(Ui_Output)
	defer free(output)
	text_backend: Test_Text_Backend_State
	facade_widget_frame(&runtime, &frame, output, &text_backend)
	defer ui_runtime_destroy(&runtime)
	defer ui_frame_end(&frame)

	u: Ui
	anim: f32
	chart: Chart_State
	values := [4]f32{1, 2, 3, 4}
	series := [1]Chart_Series{{name = "s", values = values[:]}}
	begin(&u, &frame, {0, 0, 400, 800})
	_ = section_header(&u, "SECTION")
	_ = status_pill(&u, "ready", Color{0, 200, 0, 255})
	progress_bar(&u, 0.5, Color{0, 120, 255, 255})
	progress_bar_animated(&u, 0.5, &anim, Color{0, 120, 255, 255})
	spinner(&u)
	sparkline(&u, values[:])
	_ = line_chart(&u, series[:], &chart, 80)
	kv_row(&u, "key", "value", Color{200, 200, 200, 255}, Color{255, 255, 255, 255})
	end(&u)

	testing.expect_value(t, u.stable_count, 0)
	testing.expect_value(t, u.focus_count, 0)
}

@(test)
facade_widgets_scale_their_slots :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	frame: Ui_Frame
	output := new(Ui_Output)
	defer free(output)
	text_backend: Test_Text_Backend_State
	facade_widget_frame(&runtime, &frame, output, &text_backend, 2)
	defer ui_runtime_destroy(&runtime)
	defer ui_frame_end(&frame)

	u: Ui
	begin(&u, &frame, {0, 0, 400, 400})
	progress_bar(&u, 0.25, Color{0, 120, 255, 255}, height = 10)
	after := remaining_rect(&u)
	end(&u)
	// A logical height of 10 consumes 20 device pixels at scale 2.
	testing.expect_value(t, after.y, i32(20))
}

@(test)
facade_widget_options_scale_once :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	frame: Ui_Frame
	output := new(Ui_Output)
	defer free(output)
	text_backend: Test_Text_Backend_State
	facade_widget_frame(&runtime, &frame, output, &text_backend, 2)
	defer ui_runtime_destroy(&runtime)
	defer ui_frame_end(&frame)

	u: Ui
	open := true
	begin(&u, &frame, {0, 0, 400, 400})
	_ = collapsible_header(
		&u,
		id(&u, "details"),
		"Details",
		&open,
		{height = 30, font_size = 10},
	)
	spinner(&u, 24, {style = .Orbit_Dots, radius = 8, dot_radius = 2, dot_count = 3})
	after := remaining_rect(&u)
	end(&u)

	// 30 logical header pixels plus a 24 logical spinner consume 108 physical pixels.
	testing.expect_value(t, after.y, i32(108))
	// The spinner emits physical dots with radius 4 at scale 2.
	found_dot := false
	for command in output.main.commands[:output.main.count] {
		if command.kind == .Circle && command.outer_radius == 4 {
			found_dot = true
			break
		}
	}
	testing.expect(t, found_dot, "logical dot radius must scale once")
}

@(test)
facade_widgets_skip_focus_when_slot_collapses :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	frame: Ui_Frame
	output := new(Ui_Output)
	defer free(output)
	text_backend: Test_Text_Backend_State
	facade_widget_frame(&runtime, &frame, output, &text_backend)
	defer ui_runtime_destroy(&runtime)
	defer ui_frame_end(&frame)

	u: Ui
	open := true
	// A zero-area root collapses every slot, so no widget may claim a
	// traversal entry a later frame would have to clean up.
	begin(&u, &frame, {0, 0, 0, 0})
	_ = collapsible_header(&u, id(&u, "details"), "Details", &open)
	_ = icon_btn(&u, id(&u, "close"), "\u2715")
	_ = section_header(&u, "SECTION")
	end(&u)

	testing.expect_value(t, u.stable_count, 0)
}

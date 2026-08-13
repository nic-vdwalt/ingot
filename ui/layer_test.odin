#+build !js
package ui

import "core:testing"

@(test)
layer_draws_in_screen_space_from_inside_a_pane :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	output := new(Ui_Output)
	defer free(output)
	frame: Ui_Frame
	frame.output = output
	ui_frame_begin(&frame, &runtime)

	ui_frame_pane_push(&frame, {50, 50})
	// Inside the layer the cumulative pane origin is zero: draw_* coordinates
	// are screen space, exactly what the overlay_* helpers used to provide.
	layer_begin(&frame, Z_POPUP)
	draw_rectangle(&frame, 5, 5, 10, 10, Color{1, 2, 3, 255})
	layer_end(&frame)
	testing.expect_value(t, output.overlay.count, 1)
	testing.expect_value(t, output.overlay.commands[0].rect.x, f32(5))
	testing.expect_value(t, output.overlay.commands[0].rect.y, f32(5))

	// After layer_end the pane translation applies again.
	draw_rectangle(&frame, 5, 5, 10, 10, Color{1, 2, 3, 255})
	testing.expect_value(t, output.main.count, 1)
	testing.expect_value(t, output.main.commands[0].rect.x, f32(55))
	testing.expect_value(t, output.main.commands[0].rect.y, f32(55))
	ui_frame_pane_pop(&frame)
	ui_frame_end(&frame)
}

@(test)
layer_claim_occludes_and_scopes :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	output := new(Ui_Output)
	defer free(output)
	frame: Ui_Frame
	frame.output = output
	ui_frame_begin(&frame, &runtime)

	// A claiming layer registers its rect with the input router.
	layer_begin(&frame, Z_POPUP, claim = Rectangle{20, 20, 40, 40})
	layer_end(&frame)
	route_begin_frame(&frame)
	testing.expect(t, route_occluded(&frame, Vector2{30, 30}))
	testing.expect(t, !route_occluded(&frame, Vector2{5, 5}))

	// A passive layer (zero claim) registers nothing.
	layer_begin(&frame, Z_TOOLTIP)
	layer_end(&frame)
	route_begin_frame(&frame)
	testing.expect(t, !route_occluded(&frame, Vector2{30, 30}))
	ui_frame_end(&frame)
}

@(test)
layers_nest_ascending :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	output := new(Ui_Output)
	defer free(output)
	frame: Ui_Frame
	frame.output = output
	ui_frame_begin(&frame, &runtime)

	layer_begin(&frame, Z_PANEL, claim = Rectangle{0, 0, 100, 100})
	draw_rectangle(&frame, 0, 0, 100, 100, Color{1, 1, 1, 255})
	layer_begin(&frame, Z_POPUP, claim = Rectangle{10, 10, 50, 50})
	draw_rectangle(&frame, 10, 10, 50, 50, Color{2, 2, 2, 255})
	layer_end(&frame)
	layer_end(&frame)

	testing.expect_value(t, output.overlay.count, 2)
	testing.expect_value(t, output.overlay.commands[0].tier, u8(1))
	testing.expect_value(t, output.overlay.commands[1].tier, u8(2))
	testing.expect_value(t, output.overlay.z_groups[output.overlay.commands[0].z_group], Z_PANEL)
	testing.expect_value(t, output.overlay.z_groups[output.overlay.commands[1].z_group], Z_POPUP)
	testing.expect_value(t, output.overlay.current_tier, u8(0))
	testing.expect_value(t, output.overlay.current_z_group, u8(0))
	ui_frame_end(&frame)
}

@(test)
modal_inside_a_pane_is_not_double_translated :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	backend: Test_Text_Backend_State
	ui_runtime_set_text_backend(
		&runtime,
		{data = &backend, font_for_size = test_text_font_for_size, measure = test_text_measure},
	)
	output := new(Ui_Output)
	defer free(output)
	frame: Ui_Frame
	frame.output = output
	ui_frame_begin(&frame, &runtime)

	// The modal opens from inside a pane, yet its layer zeroes the origin, so
	// the dim and panel land at exact screen coordinates.
	ui_frame_pane_push(&frame, {50, 50})
	st := Modal_State {
		open = true,
	}
	modal_begin(&frame, &st, "Title", {size = {200, 120}, screen = {0, 0, 640, 480}})
	testing.expect(t, output.overlay.count >= 2)
	// commands[0] is the full-screen dim, commands[1] the centered panel.
	testing.expect_value(t, output.overlay.commands[0].rect.x, f32(0))
	testing.expect_value(t, output.overlay.commands[0].rect.width, f32(640))
	testing.expect_value(t, output.overlay.commands[1].rect.x, f32(220))
	testing.expect_value(t, output.overlay.commands[1].rect.y, f32(180))
	modal_end(&st)
	ui_frame_pane_pop(&frame)
	ui_frame_end(&frame)
}

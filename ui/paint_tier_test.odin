#+build !js
package ui

import "core:testing"

@(test)
z_paint_tier_buckets_named_and_intermediate_tiers :: proc(t: ^testing.T) {
	testing.expect_value(t, z_paint_tier(Z_CONTENT), u8(0))
	testing.expect_value(t, z_paint_tier(Z_NONE), u8(0))
	testing.expect_value(t, z_paint_tier(Z_PANEL), u8(1))
	testing.expect_value(t, z_paint_tier(Z_PANEL + 50), u8(1))
	testing.expect_value(t, z_paint_tier(Z_POPUP), u8(2))
	testing.expect_value(t, z_paint_tier(Z_MODAL), u8(3))
	testing.expect_value(t, z_paint_tier(Z_TOAST), u8(4))
	testing.expect_value(t, z_paint_tier(Z_TOOLTIP), u8(5))
	testing.expect_value(t, z_paint_tier(Z_TOOLTIP + 1000), u8(5))
}

@(test)
z_scope_promotes_draws_to_the_overlay_at_its_tier :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	output := new(Ui_Output)
	defer free(output)
	frame: Ui_Frame
	frame.output = output
	ui_frame_begin(&frame, &runtime)

	draw_rectangle(&frame, 0, 0, 10, 10, Color{255, 0, 0, 255})
	testing.expect_value(t, output.main.count, 1)
	testing.expect_value(t, output.overlay.count, 0)

	z_scope_begin(&frame, Z_MODAL)
	draw_rectangle(&frame, 1, 1, 8, 8, Color{0, 255, 0, 255})
	z_scope_end(&frame)
	testing.expect_value(t, output.main.count, 1)
	testing.expect_value(t, output.overlay.count, 1)
	testing.expect_value(t, output.overlay.commands[0].tier, u8(3))

	draw_rectangle(&frame, 2, 2, 6, 6, Color{0, 0, 255, 255})
	testing.expect_value(t, output.main.count, 2)
	testing.expect_value(t, output.main.commands[1].tier, u8(0))
	ui_frame_end(&frame)
}

@(test)
passive_overlay_groups_stamp_their_declared_tier :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	output := new(Ui_Output)
	defer free(output)
	frame: Ui_Frame
	frame.output = output
	ui_frame_begin(&frame, &runtime)

	overlay_begin(&frame, Rectangle{0, 0, 40, 20}, claim_input = false, z = Z_TOAST)
	overlay_rect(&frame, Rectangle{0, 0, 40, 20}, Color{9, 9, 9, 255})
	overlay_end(&frame)
	overlay_begin(&frame, Rectangle{0, 0, 40, 20}, claim_input = false, z = Z_TOOLTIP)
	overlay_rect(&frame, Rectangle{0, 0, 40, 20}, Color{8, 8, 8, 255})
	overlay_end(&frame)

	testing.expect_value(t, output.overlay.count, 2)
	testing.expect_value(t, output.overlay.commands[0].tier, u8(4))
	testing.expect_value(t, output.overlay.commands[1].tier, u8(5))
	// The ambient tier is restored after each group closes.
	testing.expect_value(t, output.overlay.current_tier, u8(0))
	ui_frame_end(&frame)
}

@(test)
modal_paints_backdrop_and_panel_into_the_modal_tier :: proc(t: ^testing.T) {
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

	st := Modal_State {
		open = true,
	}
	body := modal_begin(&frame, &st, "Title", {size = {200, 120}, screen = {0, 0, 640, 480}})
	testing.expect(t, body.w > 0)
	// Everything the modal painted - dim, panel, outline, clip, title - landed
	// in the overlay channel at the modal tier; main gained nothing.
	testing.expect_value(t, output.main.count, 0)
	testing.expect(t, output.overlay.count >= 5)
	for index in 0 ..< output.overlay.count {
		testing.expect_value(t, output.overlay.commands[index].tier, u8(3))
	}
	modal_end(&st)
	ui_frame_end(&frame)
	testing.expect_value(t, output.overlay.clip_count, 0)
}

@(test)
clip_pairs_stay_within_one_tier_while_other_tiers_interleave :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	output := new(Ui_Output)
	defer free(output)
	frame: Ui_Frame
	frame.output = output
	ui_frame_begin(&frame, &runtime)

	z_scope_begin(&frame, Z_MODAL)
	begin_scissor_mode(&frame, 0, 0, 100, 100)
	draw_rectangle(&frame, 1, 1, 5, 5, Color{1, 1, 1, 255})
	// A passive tooltip group inside the modal's scissor: its commands carry
	// the tooltip tier, so the per-tier replay scans lift them outside the
	// modal's clip pair.
	overlay_begin(&frame, Rectangle{0, 0, 20, 20}, claim_input = false, z = Z_TOOLTIP)
	overlay_rect(&frame, Rectangle{0, 0, 20, 20}, Color{2, 2, 2, 255})
	overlay_end(&frame)
	end_scissor_mode(&frame)
	z_scope_end(&frame)

	testing.expect_value(t, output.overlay.count, 4)
	testing.expect_value(t, output.overlay.commands[0].kind, Paint_Kind.Clip_Begin)
	testing.expect_value(t, output.overlay.commands[0].tier, u8(3))
	testing.expect_value(t, output.overlay.commands[1].tier, u8(3))
	testing.expect_value(t, output.overlay.commands[2].tier, u8(5))
	testing.expect_value(t, output.overlay.commands[3].kind, Paint_Kind.Clip_End)
	testing.expect_value(t, output.overlay.commands[3].tier, u8(3))
	testing.expect_value(t, output.overlay.clip_count, 0)
	ui_frame_end(&frame)
}

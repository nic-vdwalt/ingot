package main

import "core:testing"
import fit "ingot:fit"

@(test)
custom_cursor_ownership_requires_a_focused_playfield :: proc(t: ^testing.T) {
	value := new(Client_State)
	defer free(value)
	value.screen = .Playing
	value.graphics_ready = true
	testing.expect(t, game_custom_cursor_active_for(value, true))
	testing.expect(t, !game_custom_cursor_active_for(value, false))
	value.pause.open = true
	testing.expect(t, !game_custom_cursor_active_for(value, true))
	value.pause.open = false
	value.balance.active = true
	testing.expect(t, !game_custom_cursor_active_for(value, true))
	value.balance.active = false
	value.graphics_ready = false
	testing.expect(t, !game_custom_cursor_active_for(value, true))
	value.graphics_ready = true
	value.screen = .Menu
	testing.expect(t, !game_custom_cursor_active_for(value, true))
}

@(test)
custom_cursor_command_counts_match_each_visual :: proc(t: ^testing.T) {
	testing.expect_value(t, cursor_visual_command_count(.Normal), 7)
	testing.expect_value(t, cursor_visual_command_count(.Target), 12)
	testing.expect_value(t, cursor_visual_command_count(.Grab), 14)
	testing.expect_value(t, cursor_visual_command_count(.Terraform), 8)
}

Cursor_Test_Draw :: struct {
	value:    ^Client_State,
	mode:     Cursor_Visual_Mode,
	saturate: bool,
}

cursor_test_surface :: proc(surface: ^fit.Surface, _: fit.Rect, user_data: rawptr) -> bool {
	assert(surface != nil && user_data != nil, "cursor test surface: invalid argument")
	draw := cast(^Cursor_Test_Draw)user_data
	if draw.saturate {
		fit.Layer_With_Reserved_Paint(
			surface,
			fit.Z_Order(500),
			fit.PAINT_COMMAND_CAP - 1,
			cursor_test_saturate,
		)
	}
	sample := Cursor_Visual_Sample {
		mode   = draw.mode,
		radius = CURSOR_RING_RADIUS,
	}
	draw.value.cursor.drawn_this_frame = cursor_draw_visual(draw.value, surface, sample)
	return false
}

cursor_test_saturate :: proc(surface: ^fit.Surface, _: rawptr) {
	assert(surface != nil, "cursor test saturation: nil surface")
	for _ in 0 ..< fit.PAINT_COMMAND_CAP - 1 {
		fit.Surface_Fill_Circle(surface, {}, 1, {})
	}
}

cursor_test_build :: proc(builder: ^fit.Builder, user_data: rawptr) {
	assert(builder != nil && user_data != nil, "cursor test build: invalid argument")
	fit.Canvas(builder, cursor_test_surface, user_data)
}

@(test)
custom_cursor_ownership_requires_complete_retained_paint :: proc(t: ^testing.T) {
	value := new(Client_State)
	defer free(value)
	driver: fit.Test_Driver
	fit.Test_Driver_Init(&driver)
	defer fit.Test_Driver_Destroy(&driver)
	draw := Cursor_Test_Draw {
		value = value,
		mode  = .Normal,
	}
	input := fit.Test_Input {
		screen_size = {320, 240},
		dpi_scale   = 1,
	}
	game_cursor_frame_begin(value)
	testing.expect(t, fit.Test_Driver_Frame(&driver, input, cursor_test_build, &draw))
	testing.expect(t, value.cursor.drawn_this_frame)
	testing.expect_value(t, fit.Test_Driver_Paint_Summary(&driver).overlay_commands, 7)
	game_cursor_frame_begin(value)
	testing.expect(t, !value.cursor.drawn_this_frame)
	draw.saturate = true
	testing.expect(t, fit.Test_Driver_Frame(&driver, input, cursor_test_build, &draw))
	testing.expect(t, !value.cursor.drawn_this_frame)
	testing.expect_value(
		t,
		fit.Test_Driver_Paint_Summary(&driver).overlay_commands,
		fit.PAINT_COMMAND_CAP - 1,
	)
	draw.mode = .Grab
	testing.expect(t, fit.Test_Driver_Frame(&driver, input, cursor_test_build, &draw))
	testing.expect(t, !value.cursor.drawn_this_frame)
}

@(test)
custom_cursor_visual_modes_prioritize_registered_targets :: proc(t: ^testing.T) {
	normal := cursor_visual_sample(false, false, false, 0)
	testing.expect_value(t, normal.mode, Cursor_Visual_Mode.Normal)
	testing.expect_value(t, normal.radius, CURSOR_RING_RADIUS)
	testing.expect_value(
		t,
		cursor_visual_sample(false, true, false, 0).mode,
		Cursor_Visual_Mode.Grab,
	)
	testing.expect_value(
		t,
		cursor_visual_sample(false, false, true, 0).mode,
		Cursor_Visual_Mode.Terraform,
	)
	testing.expect_value(
		t,
		cursor_visual_sample(true, true, true, 0).mode,
		Cursor_Visual_Mode.Target,
	)
}

@(test)
custom_cursor_click_pulse_is_bounded_on_targets :: proc(t: ^testing.T) {
	idle := cursor_visual_sample(true, false, false, 0)
	clicked := cursor_visual_sample(true, false, false, 1)
	below := cursor_visual_sample(true, false, false, -10)
	above := cursor_visual_sample(true, false, false, 10)
	testing.expect(t, clicked.radius > idle.radius)
	testing.expect_value(t, below.radius, idle.radius)
	testing.expect_value(t, above.radius, clicked.radius)
}

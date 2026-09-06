#+build !js
package main

import "core:testing"
import fit "ingot:fit"

@(test)
preview_balances_clipping_at_multiple_scales :: proc(t: ^testing.T) {
	for scale in 1 ..= 2 {
		driver: fit.Test_Driver
		fit.Test_Driver_Init(&driver)
		data := State {
			active_tab = 2,
		}
		input := fit.Test_Input {
			screen_size = {1520, 1120},
			dpi_scale   = f32(scale),
		}
		testing.expect(t, fit.Test_Driver_Frame(&driver, input, draw, &data))
		summary := fit.Test_Driver_Paint_Summary(&driver)
		testing.expect(t, summary.main_geometry_commands > 0)
		testing.expect_value(t, summary.main_clip_depth, 0)
		testing.expect_value(t, summary.overlay_clip_depth, 0)
		diagnostics := fit.Test_Driver_Diagnostics(&driver)
		testing.expect_value(t, diagnostics.main_commands_dropped, i32(0))
		testing.expect_value(t, diagnostics.layout_overflows, i32(0))
		testing.expect(t, fit.Test_Driver_Frame(&driver, input, draw, &data))
		baseline := fit.Test_Driver_Telemetry(&driver)
		testing.expect(t, fit.Test_Driver_Frame(&driver, input, draw, &data))
		steady := fit.Test_Driver_Telemetry(&driver)
		testing.expect_value(t, steady.scratch_allocations, baseline.scratch_allocations)
		testing.expect_value(t, steady.scratch_resizes, baseline.scratch_resizes)
		testing.expect_value(t, steady.render_relayouts, baseline.render_relayouts)
		destroy_state(&data)
		fit.Test_Driver_Destroy(&driver)
	}
}

Preview_Test_State :: struct {
	rect:  fit.Rect,
	inset: i32,
}

preview_test_render :: proc(surface: ^fit.Surface, rect: fit.Rect, user_data: rawptr) -> bool {
	data := cast(^Preview_Test_State)user_data
	data.rect = rect
	data.inset = min(fit.Px(surface, 8), min(rect.w, rect.h) / 2)
	return preview_render(surface, rect, nil)
}

preview_test_draw :: proc(builder: ^fit.Builder, user_data: rawptr) {
	fit.Canvas_Leaf(
		fit.Column(builder),
		{intrinsic = {w = 160, h = 48}},
		preview_test_render,
		user_data,
	)
}

@(test)
preview_geometry_stays_inside_physical_bounds :: proc(t: ^testing.T) {
	for scale in 1 ..= 2 {
		driver: fit.Test_Driver
		fit.Test_Driver_Init(&driver)
		data: Preview_Test_State
		input := fit.Test_Input {
			screen_size = {640, 480},
			dpi_scale   = f32(scale),
		}
		testing.expect(t, fit.Test_Driver_Frame(&driver, input, preview_test_draw, &data))
		testing.expect_value(t, data.rect.w, i32(160))
		testing.expect_value(t, data.rect.h, i32(48))
		impl := cast(^fit.Test_Driver_Impl)driver.inner
		paint := &impl.output.main
		rectangle_count := 0
		for command in paint.commands[:paint.count] {
			if command.kind != .Rectangle do continue
			inset := f32(0)
			if rectangle_count == 1 do inset = f32(data.inset)
			testing.expect_value(t, command.rect.x, f32(data.rect.x) + inset)
			testing.expect_value(t, command.rect.y, f32(data.rect.y) + inset)
			testing.expect_value(t, command.rect.width, f32(data.rect.w) - 2 * inset)
			testing.expect_value(t, command.rect.height, f32(data.rect.h) - 2 * inset)
			rectangle_count += 1
		}
		testing.expect_value(t, rectangle_count, 2)
		testing.expect_value(t, paint.clip_count, 0)
		fit.Test_Driver_Destroy(&driver)
	}
}

Preference_Test_State :: struct {
	values:     [2]Workspace_Preference,
	reversed:   bool,
	hide_first: bool,
}

preference_test_draw :: proc(builder: ^fit.Builder, user_data: rawptr) {
	data := cast(^Preference_Test_State)user_data
	root := fit.Column(builder)
	for position in 0 ..< 2 {
		index := position
		if data.reversed do index = 1 - position
		if data.hide_first && index == 0 do continue
		draw_preference(root, u64(index + 101), &data.values[index])
	}
}

@(test)
preferences_are_isolated_across_reorder_and_removal :: proc(t: ^testing.T) {
	driver: fit.Test_Driver
	fit.Test_Driver_Init(&driver)
	defer fit.Test_Driver_Destroy(&driver)
	fit.Test_Driver_Set_Semantics(&driver, true)
	data: Preference_Test_State
	input := fit.Test_Input {
		screen_size = {760, 560},
		dpi_scale   = 1,
	}
	testing.expect(t, fit.Test_Driver_Frame(&driver, input, preference_test_draw, &data))
	input.keys_pressed[int(fit.Key.Tab)] = true
	testing.expect(t, fit.Test_Driver_Frame(&driver, input, preference_test_draw, &data))
	input.keys_pressed = {}
	input.keys_pressed[int(fit.Key.Enter)] = true
	testing.expect(t, fit.Test_Driver_Frame(&driver, input, preference_test_draw, &data))
	testing.expect(t, data.values[0].enabled && !data.values[1].enabled)
	input.keys_pressed = {}
	data.reversed = true
	testing.expect(t, fit.Test_Driver_Frame(&driver, input, preference_test_draw, &data))
	data.hide_first = true
	testing.expect(t, fit.Test_Driver_Frame(&driver, input, preference_test_draw, &data))
	data.hide_first = false
	testing.expect(t, fit.Test_Driver_Frame(&driver, input, preference_test_draw, &data))
	testing.expect(t, data.values[0].enabled && !data.values[1].enabled)
	testing.expect_value(t, fit.Test_Driver_Diagnostics(&driver).semantic_id_collisions, i32(0))
}

builder_controls_test_frame :: proc(
	driver: ^fit.Test_Driver,
	state: ^State,
	key: fit.Key,
	press_key: bool = false,
) -> bool {
	assert(driver != nil && state != nil, "builder controls test frame: invalid argument")
	input := fit.Test_Input {
		screen_size = {760, 560},
		dpi_scale   = 1,
	}
	if press_key do input.keys_pressed[int(key)] = true
	return fit.Test_Driver_Frame(driver, input, draw, state)
}

@(test)
builder_controls_builds_and_emits_semantics :: proc(t: ^testing.T) {
	driver: fit.Test_Driver
	fit.Test_Driver_Init(&driver)
	defer fit.Test_Driver_Destroy(&driver)
	fit.Test_Driver_Set_Semantics(&driver, true)
	state := State {
		notifications_enabled = true,
		quality               = 1,
		workspace             = 101,
	}
	defer destroy_state(&state)

	testing.expect(t, builder_controls_test_frame(&driver, &state, .Tab))
	summary := fit.Test_Driver_Paint_Summary(&driver)
	testing.expect(t, summary.main_commands > 0)
	testing.expect(t, summary.main_geometry_commands > 0)
	testing.expect(t, summary.semantic_nodes >= 5)
}

@(test)
builder_controls_keyboard_changes_caller_owned_state :: proc(t: ^testing.T) {
	driver: fit.Test_Driver
	fit.Test_Driver_Init(&driver)
	defer fit.Test_Driver_Destroy(&driver)
	state := State {
		notifications_enabled = true,
		quality               = 1,
		workspace             = 101,
	}
	defer destroy_state(&state)

	testing.expect(t, builder_controls_test_frame(&driver, &state, .Tab))
	for _ in 0 ..< 4 {
		testing.expect(t, builder_controls_test_frame(&driver, &state, .Tab, true))
	}
	testing.expect(t, builder_controls_test_frame(&driver, &state, .Enter, true))
	testing.expect(t, !state.notifications_enabled)
	testing.expect(t, builder_controls_test_frame(&driver, &state, .Tab))
	testing.expect(t, !state.notifications_enabled)
}

@(test)
builder_controls_keyboard_changes_tabs_and_persists :: proc(t: ^testing.T) {
	driver: fit.Test_Driver
	fit.Test_Driver_Init(&driver)
	defer fit.Test_Driver_Destroy(&driver)
	state := State {
		notifications_enabled = true,
		quality               = 1,
		workspace             = 101,
	}
	defer destroy_state(&state)

	testing.expect(t, builder_controls_test_frame(&driver, &state, .Tab))
	testing.expect(t, builder_controls_test_frame(&driver, &state, .Tab, true))
	testing.expect(t, builder_controls_test_frame(&driver, &state, .Tab, true))
	testing.expect(t, builder_controls_test_frame(&driver, &state, .Enter, true))
	testing.expect_value(t, state.active_tab, i32(1))
	testing.expect(t, builder_controls_test_frame(&driver, &state, .Tab))
	testing.expect_value(t, state.active_tab, i32(1))
}

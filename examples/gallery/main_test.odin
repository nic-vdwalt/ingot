#+build !js
package main

import "core:testing"
import "ingot:examples/gallery/imsh"
import fit "ingot:fit"

Gallery_Pilot_Test_State :: struct {
	region:  fit.Region,
	widgets: Widget_State,
	button:  fit.Control_Motion_State,
	header:  fit.Control_Motion_State,
	open:    bool,
	clicks:  int,
}

gallery_pilot_draw :: proc(builder: ^fit.Builder, user_data: rawptr) {
	fit.canvas(builder, gallery_pilot_render, user_data)
}

gallery_pilot_render :: proc(surface: ^fit.Surface, rect: fit.Rect, user_data: rawptr) -> bool {
	state := cast(^Gallery_Pilot_Test_State)user_data
	region := fit.region_open(surface, &state.region, rect, {scope = "pilot"})
	if fit.region_button(region, "button", "Button", motion = &state.button) do state.clicks += 1
	_ = fit.region_toggle(
		region,
		"toggle",
		"Preview",
		&state.widgets.toggle,
		&state.widgets.toggle_motion,
	)
	draw_widget_volume(region, surface, &state.widgets)
	_ = fit.region_tab_bar(
		region,
		"tabs",
		[]string{"First", "Second"},
		&state.widgets.tab_active,
		&state.widgets.tabs_motion,
	)
	_ = fit.region_collapsible_header(
		region,
		"header",
		"Details",
		&state.open,
		{motion = &state.header},
	)
	_ = fit.region_close(region)
	return false
}

@(test)
gallery_pilot_keeps_values_caller_owned :: proc(t: ^testing.T) {
	driver: fit.Test_Driver
	fit.test_driver_init(&driver)
	defer fit.test_driver_destroy(&driver)
	theme := palette_theme(.Ingot)
	fit.test_driver_set_theme(&driver, theme)
	state := Gallery_Pilot_Test_State {
		widgets = {volume = 40},
	}
	input := fit.Test_Input {
		screen_size = {800, 600},
		dpi_scale   = 1,
		frame_time  = 1.0 / 60.0,
	}
	testing.expect(t, fit.test_driver_frame(&driver, input, gallery_pilot_draw, &state))
	state.widgets.toggle, state.open = true, true
	state.widgets.tab_active = 1
	testing.expect(t, fit.test_driver_frame(&driver, input, gallery_pilot_draw, &state))
	testing.expect_value(t, state.widgets.toggle_motion.value.current, f32(1))
	testing.expect_value(t, state.header.value.current, f32(1))
	testing.expect(
		t,
		state.widgets.tabs_motion.indicator.current == state.widgets.tabs_motion.indicator.target,
	)
	testing.expect_value(t, state.widgets.volume, f32(40))
	input.mouse_position = {10, 10}
	input.mouse_pressed[0], input.mouse_down[0] = true, true
	testing.expect(t, fit.test_driver_frame(&driver, input, gallery_pilot_draw, &state))
	input.mouse_pressed[0], input.mouse_down[0], input.mouse_released[0] = false, false, true
	testing.expect(t, fit.test_driver_frame(&driver, input, gallery_pilot_draw, &state))
	testing.expect_value(t, state.clicks, 1)
	input.mouse_released[0] = false
	input.mouse_position = {10, 40}
	input.mouse_pressed[0], input.mouse_down[0] = true, true
	testing.expect(t, fit.test_driver_frame(&driver, input, gallery_pilot_draw, &state))
	input.mouse_pressed[0], input.mouse_down[0], input.mouse_released[0] = false, false, true
	testing.expect(t, fit.test_driver_frame(&driver, input, gallery_pilot_draw, &state))
	testing.expect(t, !state.widgets.toggle)
	state.widgets.toggle = true
	fit.theme_set_reduced_motion(&theme, true)
	fit.test_driver_set_theme(&driver, theme)
	input.mouse_released[0] = false
	testing.expect(t, fit.test_driver_frame(&driver, input, gallery_pilot_draw, &state))
	testing.expect_value(t, state.widgets.toggle_motion.value.current, f32(1))
	testing.expect_value(t, state.header.value.current, f32(1))
	fit.theme_set_reduced_motion(&theme, false)
	fit.test_driver_set_theme(&driver, theme)
	state.widgets.toggle, state.open = false, false
	testing.expect(t, fit.test_driver_frame(&driver, input, gallery_pilot_draw, &state))
	testing.expect_value(t, state.widgets.toggle_motion.value.current, f32(0))
	testing.expect_value(t, state.header.value.current, f32(0))
}

Gallery_Input_Test_State :: struct {
	region: fit.Region,
	box:    fit.Input_Box,
}

@(private = "file")
gallery_input_test_draw :: proc(builder: ^fit.Builder, user_data: rawptr) {
	fit.canvas(builder, gallery_input_test_render, user_data)
}

@(private = "file")
gallery_input_test_render :: proc(
	surface: ^fit.Surface,
	rect: fit.Rect,
	user_data: rawptr,
) -> bool {
	state := cast(^Gallery_Input_Test_State)user_data
	region := fit.region_open(surface, &state.region, rect, {scope = "inputs"})
	_ = fit.region_text_input(region, "name", &state.box, "Name", {semantics = {name = "Name"}})
	_ = fit.region_close(region)
	return false
}

@(test)
gallery_input_region_retains_focus_between_frames :: proc(t: ^testing.T) {
	driver: fit.Test_Driver
	fit.test_driver_init(&driver)
	defer fit.test_driver_destroy(&driver)
	state: Gallery_Input_Test_State
	defer fit.input_box_destroy(&state.box)

	pressed: fit.Test_Input
	pressed.mouse_position = {10, 10}
	pressed.mouse_pressed[0] = true
	_ = fit.test_driver_frame(&driver, pressed, gallery_input_test_draw, &state)

	typed: fit.Test_Input
	typed.characters[0] = 'x'
	typed.character_count = 1
	_ = fit.test_driver_frame(&driver, typed, gallery_input_test_draw, &state)
	testing.expect_value(t, fit.input_box_text(&state.box), "x")
}

Gallery_Buttons_Test_State :: struct {
	region: fit.Region,
	clicks: int,
}

@(private = "file")
gallery_buttons_test_draw :: proc(builder: ^fit.Builder, user_data: rawptr) {
	fit.canvas(builder, gallery_buttons_test_render, user_data)
}

@(private = "file")
gallery_buttons_test_render :: proc(
	surface: ^fit.Surface,
	rect: fit.Rect,
	user_data: rawptr,
) -> bool {
	state := cast(^Gallery_Buttons_Test_State)user_data
	region := fit.region_open(surface, &state.region, rect, {scope = "buttons"})
	for index in 0 ..< 3 {
		if fit.region_button(region, u64(index + 1), "Focusable") do state.clicks += 1
	}
	_ = fit.region_close(region)
	return false
}

@(test)
gallery_buttons_region_retains_tab_focus_between_frames :: proc(t: ^testing.T) {
	driver: fit.Test_Driver
	fit.test_driver_init(&driver)
	defer fit.test_driver_destroy(&driver)
	state: Gallery_Buttons_Test_State
	_ = fit.test_driver_frame(&driver, {}, gallery_buttons_test_draw, &state)

	activate: fit.Test_Input
	activate.keys_pressed[int(fit.Key.Tab)] = true
	activate.keys_pressed[int(fit.Key.Enter)] = true
	_ = fit.test_driver_frame(&driver, activate, gallery_buttons_test_draw, &state)
	testing.expect_value(t, state.clicks, 1)
}

@(test)
gallery_buttons_click_before_keyboard_focus :: proc(t: ^testing.T) {
	driver: fit.Test_Driver
	fit.test_driver_init(&driver)
	defer fit.test_driver_destroy(&driver)
	state: Gallery_Buttons_Test_State

	pressed: fit.Test_Input
	pressed.mouse_position = {10, 10}
	pressed.mouse_pressed[0] = true
	pressed.mouse_down[0] = true
	_ = fit.test_driver_frame(&driver, pressed, gallery_buttons_test_draw, &state)
	resolved: fit.Test_Input
	resolved.mouse_position = pressed.mouse_position
	resolved.mouse_released[0] = true
	_ = fit.test_driver_frame(&driver, resolved, gallery_buttons_test_draw, &state)
	testing.expect_value(t, state.clicks, 1)
}

@(test)
nav_strip_respects_scaled_width_and_sidebar_height :: proc(t: ^testing.T) {
	scales := [?]f32{0.5, 1, 1.5, 2, 3}
	heights := [?]i32{290, 578, 866, 1154, 1730}
	for scale, index in scales {
		minimum := nav_sidebar_min_height_scale(scale)
		testing.expect_value(t, minimum, heights[index])
		width := gallery_scaled(NARROW_WIDTH_MAX, scale)
		testing.expect(t, nav_uses_strip_scale(scale, width, minimum))
		testing.expect(t, nav_uses_strip_scale(scale, width + 1, minimum - 1))
		testing.expect(t, !nav_uses_strip_scale(scale, width + 1, minimum))
	}
}

// GALLERY_TEST_HEADER_H mirrors ui TAB_BAR_HEIGHT = si(35, s) (ui/scale.odin),
// the header height draw_content subtracts before the strip.
GALLERY_TEST_HEADER_H :: 35

// The mobile crash: at 200% on a portrait phone the full strip was taller than
// the canvas, so the content pane's height went negative and pane_begin's
// assertion trapped the wasm module. The strip must now always leave the pane
// a non-negative height, across every preset scale and phone-shaped viewport.
@(test)
nav_strip_never_pushes_content_below_zero :: proc(t: ^testing.T) {
	scales := [?]f32{0.5, 1, 1.25, 1.5, 1.75, 2}
	viewports := [?][2]i32{{390, 844}, {358, 658}, {844, 390}, {844, 150}, {320, 568}, {1, 1}}
	for scale in scales {
		header := gallery_scaled(GALLERY_TEST_HEADER_H, scale)
		for viewport in viewports {
			available := max(viewport.y - header, 0)
			strip := nav_strip_height_scale(scale, viewport.x, available)
			testing.expect(t, strip >= 0 && strip <= available)
			testing.expect(t, viewport.y - header - strip >= 0 || available == 0)
		}
	}
	header := gallery_scaled(GALLERY_TEST_HEADER_H, 2)
	available := i32(658) - header
	testing.expect(t, nav_strip_uses_compact_scale(2, 358, available))
	content := available - nav_strip_height_scale(2, 358, available)
	testing.expect(t, content >= 300)
}

@(test)
gallery_contract_keeps_sections_geometry_and_stress_scale :: proc(t: ^testing.T) {
	testing.expect_value(t, len(Section), 10)
	testing.expect_value(t, len(Palette), 10)
	testing.expect_value(t, palette, Palette.Ingot)
	testing.expect_value(t, len(SECTION_NAMES), len(Section))
	testing.expect_value(t, len(SECTION_LAYERS), len(Section))
	testing.expect_value(t, len(SECTION_AXES), len(Section))
	testing.expect_value(t, len(SECTION_BLURBS), len(Section))
	testing.expect_value(t, len(SECTION_ICONS), len(Section))
	testing.expect_value(t, len(SECTION_GROUPS), len(Section))
	testing.expect_value(t, Section(0), Section.Showcase)
	testing.expect_value(t, NARROW_WIDTH_MAX, 640)
	testing.expect_value(t, NAV_W, 200)
	testing.expect_value(t, NAV_STRIP_ROW_H, 34)
	testing.expect_value(t, NAV_STRIP_CELL_W, 116)
	testing.expect_value(t, STRESS_BUTTONS, 1000)
}

GALLERY_TEST_INPUT :: fit.Test_Input {
	screen_size = {900, 700},
	dpi_scale   = 1,
	frame_time  = 1.0 / 60.0,
}

@(private = "file")
gallery_showcase_test_draw :: proc(builder: ^fit.Builder, user_data: rawptr) {
	fit.canvas(builder, gallery_showcase_test_render, user_data)
}

@(private = "file")
gallery_showcase_test_render :: proc(
	surface: ^fit.Surface,
	rect: fit.Rect,
	user_data: rawptr,
) -> bool {
	_ = user_data
	_ = draw_showcase(surface, rect.x, rect.y, rect.w)
	return false
}

// Test_Driver has no renderer, so the Showcase must fall back to its
// placeholder and report why rather than touching gfx.
@(test)
gallery_showcase_renders_placeholder_without_gpu :: proc(t: ^testing.T) {
	driver: fit.Test_Driver
	fit.test_driver_init(&driver)
	defer fit.test_driver_destroy(&driver)
	saved := showcase
	defer showcase = saved
	showcase = {}
	testing.expect(
		t,
		fit.test_driver_frame(&driver, GALLERY_TEST_INPUT, gallery_showcase_test_draw, nil),
	)
	testing.expect(t, showcase.attempted, "first Showcase frame attempts the load")
	testing.expect_value(t, showcase.load_error, Showcase_Load_Error.Disabled)
	testing.expect(t, !showcase_ready(&showcase))
	summary := fit.test_driver_paint_summary(&driver)
	testing.expect(t, summary.main_text_bytes > 0, "placeholder and info text draw")
}

@(private = "file")
gallery_explore_test_draw :: proc(builder: ^fit.Builder, user_data: rawptr) {
	fit.canvas(builder, gallery_explore_test_render, user_data)
}

@(private = "file")
gallery_explore_test_render :: proc(
	surface: ^fit.Surface,
	rect: fit.Rect,
	user_data: rawptr,
) -> bool {
	_ = user_data
	_ = draw_showcase_explore(surface, rect.x, rect.y, 400)
	return false
}

@(test)
gallery_explore_card_click_selects_section :: proc(t: ^testing.T) {
	driver: fit.Test_Driver
	fit.test_driver_init(&driver)
	defer fit.test_driver_destroy(&driver)
	saved := section
	defer section = saved
	section = .Showcase
	input := GALLERY_TEST_INPUT
	_ = fit.test_driver_frame(&driver, input, gallery_explore_test_draw, nil)
	// At 400 px one card per row: the first card is Buttons, at the origin.
	input.mouse_position = {20, 20}
	input.mouse_pressed[0], input.mouse_down[0] = true, true
	_ = fit.test_driver_frame(&driver, input, gallery_explore_test_draw, nil)
	input.mouse_pressed[0], input.mouse_down[0], input.mouse_released[0] = false, false, true
	_ = fit.test_driver_frame(&driver, input, gallery_explore_test_draw, nil)
	testing.expect_value(t, section, Section.Buttons)
}

@(private = "file")
gallery_palette_test_draw :: proc(builder: ^fit.Builder, user_data: rawptr) {
	fit.canvas(builder, gallery_palette_test_render, user_data)
}

@(private = "file")
gallery_palette_test_render :: proc(
	surface: ^fit.Surface,
	rect: fit.Rect,
	user_data: rawptr,
) -> bool {
	_ = rect
	_ = user_data
	draw_gallery_palette(surface)
	return false
}

@(test)
gallery_palette_shortcut_filters_and_navigates :: proc(t: ^testing.T) {
	driver: fit.Test_Driver
	fit.test_driver_init(&driver)
	defer fit.test_driver_destroy(&driver)
	saved_section := section
	defer section = saved_section
	defer palette_destroy()
	section = .Showcase
	command_palette_open = false

	shortcut := GALLERY_TEST_INPUT
	shortcut.keys_down[int(fit.Key.Left_Control)] = true
	shortcut.keys_pressed[int(fit.Key.K)] = true
	_ = fit.test_driver_frame(&driver, shortcut, gallery_palette_test_draw, nil)
	testing.expect(t, command_palette_open, "Ctrl+K opens the palette")

	typed := GALLERY_TEST_INPUT
	for r, index in "charts" do typed.characters[index] = r
	typed.character_count = len("charts")
	_ = fit.test_driver_frame(&driver, typed, gallery_palette_test_draw, nil)
	testing.expect_value(t, command_palette_state.match_count, 1)

	enter := GALLERY_TEST_INPUT
	enter.keys_pressed[int(fit.Key.Enter)] = true
	_ = fit.test_driver_frame(&driver, enter, gallery_palette_test_draw, nil)
	testing.expect_value(t, section, Section.Charts)
	testing.expect(t, !command_palette_open, "activation closes the palette")
}

@(test)
gallery_palette_items_cover_every_section_once :: proc(t: ^testing.T) {
	palette_items_build()
	for s in Section {
		found := 0
		for item in palette_items {
			if item.command == palette_section_command(s) do found += 1
		}
		testing.expect_value(t, found, 1)
	}
}

@(test)
gallery_model_asset_decodes_and_rejects_corruption :: proc(t: ^testing.T) {
	vertices, indices, info, err := showcase_decode(PLANET_MESH)
	defer delete(vertices)
	defer delete(indices)
	testing.expect_value(t, err, imsh.Error.None)
	testing.expect_value(t, len(vertices), int(info.vertex_count))
	testing.expect_value(t, len(indices), int(info.index_count))
	testing.expect(t, info.index_count / 3 > 10_000, "planet keeps real detail")
	for index in indices do testing.expect(t, index < info.vertex_count)

	mesh := make([]u8, len(PLANET_MESH), context.temp_allocator)
	copy(mesh, PLANET_MESH)
	_, _, _, truncated := showcase_decode(mesh[:len(mesh) - 2])
	testing.expect_value(t, truncated, imsh.Error.Size_Mismatch)
	mesh[1] = 'X'
	_, _, _, magic := showcase_decode(mesh)
	testing.expect_value(t, magic, imsh.Error.Bad_Magic)
}

@(test)
gallery_reduced_motion_stops_planet_rotation :: proc(t: ^testing.T) {
	saved := reduced_motion
	defer reduced_motion = saved
	state := Showcase_State {
		attempted   = true,
		auto_rotate = true,
		speed       = SHOWCASE_SPEED_DEFAULT,
	}
	reduced_motion = false
	testing.expect(t, showcase_animating(&state), "rotating planet keeps requesting frames")
	reduced_motion = true
	testing.expect(t, !showcase_animating(&state), "reduced motion stops the spin")
	reduced_motion = false
	state.fixed_yaw = f32(0.6)
	testing.expect(t, !showcase_animating(&state), "a pinned capture yaw never animates")
	state.fixed_yaw = nil
	state.auto_rotate = false
	testing.expect(t, !showcase_animating(&state), "paused planet lets the gallery idle")
}

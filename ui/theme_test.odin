#+build !js
package ui

import "core:testing"

@(test)
theme_runtime_defaults_to_ingot :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	ingot := theme_retro_ingot()
	testing.expect_value(t, runtime.style.bg_color, ingot.bg_color)
	testing.expect_value(t, runtime.style.fg_primary, ingot.fg_primary)
}

@(test)
theme_runtime_swaps_palette :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	ui_runtime_set_theme(&runtime, theme_light())
	testing.expect_value(t, runtime.style.bg_color, theme_light().bg_color)
	testing.expect_value(t, runtime.style.bg_app, theme_light().bg_app_windowed)
	testing.expect_value(t, runtime.style.bg_panel, theme_light().bg_panel_windowed)
}

@(test)
theme_runtime_glass_fullscreen_toggle :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	ui_runtime_set_glass_fullscreen(&runtime, true)
	testing.expect_value(t, runtime.style.bg_app, runtime.style.bg_app_fullscreen)
	testing.expect_value(t, runtime.style.bg_chat, runtime.style.bg_chat_fullscreen)
	ui_runtime_set_glass_fullscreen(&runtime, false)
	testing.expect_value(t, runtime.style.bg_app, runtime.style.bg_app_windowed)
	testing.expect_value(t, runtime.style.bg_panel, runtime.style.bg_panel_windowed)
}

@(test)
theme_palettes_are_readable :: proc(t: ^testing.T) {
	palettes := [7]Theme {
		theme_dark(),
		theme_light(),
		theme_retro_orange(),
		theme_retro_orange_dark(),
		theme_retro_ingot(),
		theme_retro_ingot_dark(),
		theme_terra(),
	}
	for pal in palettes {
		testing.expect_value(t, pal.fg_primary.a, u8(255))
		testing.expect_value(t, pal.fg_heading.a, u8(255))
		fg := int(pal.fg_primary.r) + int(pal.fg_primary.g) + int(pal.fg_primary.b)
		bg := int(pal.bg_color.r) + int(pal.bg_color.g) + int(pal.bg_color.b)
		diff := fg - bg if fg > bg else bg - fg
		testing.expect(t, diff > 300, "fg/bg contrast too low")
	}
}

@(test)
retro_orange_theme_has_distinct_control_states :: proc(t: ^testing.T) {
	style := theme_retro_orange()
	testing.expect(t, style.bg_color.r > style.bg_color.b)
	testing.expect(t, style.button_bg != style.button_hover)
	testing.expect(t, style.button_hover != style.button_pressed)
	testing.expect(t, style.border_color != style.button_bg)
	testing.expect(t, contrast_ratio(style.button_text, style.button_bg) >= MIN_TEXT_CONTRAST)
}

@(test)
retro_orange_dark_theme_has_distinct_control_states :: proc(t: ^testing.T) {
	style := theme_retro_orange_dark()
	testing.expect_value(t, style.bg_color, Color{28, 20, 15, 255})
	testing.expect_value(t, style.fg_accent, Color{255, 170, 92, 255})
	testing.expect(t, style.button_bg != style.button_hover)
	testing.expect(t, style.button_hover != style.button_pressed)
	testing.expect(t, style.caption_hover != style.caption_pressed)
	testing.expect(t, contrast_ratio(style.button_text, style.button_bg) >= MIN_TEXT_CONTRAST)
}

@(test)
retro_ingot_theme_uses_logo_grays_and_distinct_control_states :: proc(t: ^testing.T) {
	style := theme_retro_ingot()
	testing.expect_value(t, style.bg_color, Color{245, 245, 247, 255})
	testing.expect_value(t, style.fg_primary, Color{17, 19, 24, 255})
	testing.expect_value(t, style.border_color, Color{115, 122, 130, 255})
	testing.expect(t, style.button_bg != style.button_hover)
	testing.expect(t, style.button_hover != style.button_pressed)
	testing.expect(t, style.caption_hover != style.caption_pressed)
	testing.expect(t, contrast_ratio(style.button_text, style.button_bg) >= MIN_TEXT_CONTRAST)
}

@(test)
retro_ingot_dark_theme_uses_steel_grays_and_distinct_control_states :: proc(t: ^testing.T) {
	style := theme_retro_ingot_dark()
	testing.expect_value(t, style.bg_color, Color{18, 20, 24, 255})
	testing.expect_value(t, style.fg_primary, Color{238, 241, 244, 255})
	testing.expect_value(t, style.border_color, Color{119, 132, 144, 255})
	testing.expect(t, style.button_bg != style.button_hover)
	testing.expect(t, style.button_hover != style.button_pressed)
	testing.expect(t, style.caption_hover != style.caption_pressed)
	testing.expect(t, contrast_ratio(style.button_text, style.button_bg) >= MIN_TEXT_CONTRAST)
}

@(test)
terra_theme_preserves_crt_channels_and_control_states :: proc(t: ^testing.T) {
	style := theme_terra()
	testing.expect_value(t, style.bg_color, Color{6, 10, 8, 255})
	testing.expect_value(t, style.fg_primary, Color{176, 255, 206, 255})
	testing.expect_value(t, style.fg_tool, Color{255, 190, 90, 255})
	testing.expect_value(t, style.fg_error, Color{255, 106, 84, 255})
	testing.expect(t, style.button_bg != style.button_hover)
	testing.expect(t, style.button_hover != style.button_pressed)
	testing.expect(t, style.caption_hover != style.caption_pressed)
	testing.expect(t, style.bg_hover != style.surface_pressed)
	testing.expect(t, style.substrate.kind == .Grid)
	testing.expect(t, contrast_ratio(style.button_text, style.button_bg) >= MIN_TEXT_CONTRAST)
}

@(test)
theme_installation_preserves_runtime_contract :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	generation := runtime.generation
	style := theme_dark()
	style.reduced_motion = true
	ui_runtime_set_theme(&runtime, style)
	testing.expect_value(t, runtime.generation, generation + 1)
	testing.expect(t, runtime.style.reduced_motion)
	testing.expect_value(t, runtime.style.bg_app, style.bg_app_windowed)
	testing.expect_value(t, runtime.style.bg_chat, style.bg_chat_windowed)
	testing.expect_value(t, runtime.style.bg_panel, style.bg_panel_windowed)
}

@(test)
theme_pigment_falls_back_to_matching_ink :: proc(t: ^testing.T) {
	style := theme_dark()
	for pigment in Pigment {
		expected := theme_ink(&style, pigment_ink(pigment))
		testing.expect_value(t, theme_pigment(&style, pigment), expected)
	}
}

@(test)
theme_validation_reports_first_failure :: proc(t: ^testing.T) {
	style := theme_dark()
	style.fg_primary = {}
	validation := Theme_Validate(style)
	testing.expect_value(t, validation.code, Theme_Validation_Code.Transparent_Foreground)
	testing.expect_value(t, validation.role, Theme_Role.Foreground_Primary)
	style = theme_dark()
	style.bg_popup = {}
	validation = Theme_Validate(style)
	testing.expect_value(t, validation.code, Theme_Validation_Code.Transparent_Background)
	testing.expect_value(t, validation.role, Theme_Role.Background_Popup)
}

@(test)
theme_try_set_rejects_without_runtime_mutation :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	before := runtime.style
	generation := runtime.generation
	invalid := theme_dark()
	invalid.fg_primary = invalid.bg_color
	validation := ui_runtime_try_set_theme(&runtime, invalid)
	testing.expect_value(t, validation.code, Theme_Validation_Code.Primary_Contrast)
	testing.expect_value(t, runtime.style, before)
	testing.expect_value(t, runtime.generation, generation)
}

@(test)
theme_palette_maps_explicit_dark_swatches :: proc(t: ^testing.T) {
	palette := Theme_Palette {
		basis                = .Dark,
		ground               = {18, 20, 24, 255},
		surface              = {28, 31, 36, 255},
		surface_raised       = {38, 42, 48, 255},
		control              = {48, 53, 61, 255},
		control_hover        = {62, 69, 79, 255},
		control_pressed      = {78, 87, 99, 255},
		foreground           = {238, 241, 244, 255},
		foreground_muted     = {174, 182, 190, 255},
		accent               = {126, 200, 255, 255},
		foreground_on_accent = {17, 19, 24, 255},
		danger               = {255, 145, 145, 255},
		foreground_on_danger = {17, 19, 24, 255},
		success              = {142, 226, 166, 255},
		border               = {104, 115, 126, 255},
		focus                = {126, 200, 255, 230},
	}
	style := Theme_From_Palette(palette)
	testing.expect_value(t, style.bg_color, palette.ground)
	testing.expect_value(t, style.bg_panel, palette.surface)
	testing.expect_value(t, style.bg_popup, palette.surface_raised)
	testing.expect_value(t, style.button_bg, palette.control)
	testing.expect_value(t, style.button_hover, palette.control_hover)
	testing.expect_value(t, style.button_pressed, palette.control_pressed)
	testing.expect_value(t, style.fg_primary, palette.foreground)
	testing.expect_value(t, style.fg_accent, palette.accent)
	testing.expect_value(t, style.fg_error, palette.danger)
	testing.expect_value(t, style.fg_success, palette.success)
	testing.expect(t, Theme_Is_Valid(style))
}

@(test)
theme_palette_maps_explicit_light_swatches :: proc(t: ^testing.T) {
	style := Theme_From_Palette(
		{
			basis = .Light,
			ground = {250, 250, 252, 255},
			surface = {240, 241, 244, 255},
			surface_raised = {232, 234, 238, 255},
			control = {215, 219, 225, 255},
			control_hover = {198, 204, 212, 255},
			control_pressed = {178, 186, 196, 255},
			foreground = {20, 24, 30, 255},
			foreground_muted = {68, 76, 86, 255},
			accent = {0, 76, 140, 255},
			foreground_on_accent = {20, 24, 30, 255},
			danger = {140, 24, 30, 255},
			foreground_on_danger = {255, 255, 255, 255},
			success = {20, 104, 54, 255},
			border = {112, 120, 130, 255},
			focus = {0, 76, 140, 230},
		},
	)
	testing.expect(t, Theme_Is_Valid(style))
	testing.expect_value(t, style.bg_app_windowed, style.bg_color)
	testing.expect_value(t, style.bg_panel_fullscreen, style.bg_secondary)
}

@(test)
theme_role_access_round_trips_every_color :: proc(t: ^testing.T) {
	style := theme_dark()
	for role in Theme_Role {
		value := Color{u8(int(role) + 1), 91, 137, 211}
		Theme_Set_Color(&style, role, value)
		testing.expect_value(t, Theme_Get_Color(style, role), value)
	}
}

@(test)
theme_non_color_properties_are_explicit :: proc(t: ^testing.T) {
	style := theme_dark()
	Theme_Set_Pigment(&style, .Accent, Color{12, 34, 56, 255})
	Theme_Set_Substrate(&style, {kind = .Ruled, margin_rule = true})
	testing.expect_value(t, style.pigments[.Accent], Color{12, 34, 56, 255})
	testing.expect_value(t, style.substrate.kind, Substrate_Kind.Ruled)
	testing.expect(t, style.substrate.margin_rule)
}

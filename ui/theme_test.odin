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

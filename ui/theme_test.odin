#+build !js
package ui

import "core:testing"

@(test)
theme_runtime_defaults_to_dark :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	testing.expect_value(t, runtime.style.bg_color, theme_dark().bg_color)
	testing.expect_value(t, runtime.style.fg_primary, theme_dark().fg_primary)
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
	for pal in ([3]Theme{theme_dark(), theme_light(), theme_retro_orange()}) {
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

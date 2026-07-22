#+build !js
package ui

import "core:testing"

@(test)
theme_defaults_to_dark :: proc(t: ^testing.T) {
	testing.expect_value(t, theme.bg_color, theme_dark().bg_color)
	testing.expect_value(t, theme.fg_primary, theme_dark().fg_primary)
}

@(test)
theme_set_theme_swaps_palette :: proc(t: ^testing.T) {
	defer set_theme(theme_dark())
	set_theme(theme_light())
	testing.expect_value(t, theme.bg_color, theme_light().bg_color)
	// Active glass surfaces reset to the windowed variants.
	testing.expect_value(t, theme.bg_app, theme_light().bg_app_windowed)
	testing.expect_value(t, theme.bg_panel, theme_light().bg_panel_windowed)
}

@(test)
theme_glass_fullscreen_toggle :: proc(t: ^testing.T) {
	defer set_theme(theme_dark())
	set_glass_fullscreen(true)
	testing.expect_value(t, theme.bg_app, theme.bg_app_fullscreen)
	testing.expect_value(t, theme.bg_chat, theme.bg_chat_fullscreen)
	set_glass_fullscreen(false)
	testing.expect_value(t, theme.bg_app, theme.bg_app_windowed)
	testing.expect_value(t, theme.bg_panel, theme.bg_panel_windowed)
}

@(test)
theme_palettes_are_readable :: proc(t: ^testing.T) {
	// Text colors must be fully opaque in both built-in palettes and text
	// must contrast against the main background (light vs dark luminance).
	for pal in ([2]Theme{theme_dark(), theme_light()}) {
		testing.expect_value(t, pal.fg_primary.a, u8(255))
		testing.expect_value(t, pal.fg_heading.a, u8(255))
		fg := int(pal.fg_primary.r) + int(pal.fg_primary.g) + int(pal.fg_primary.b)
		bg := int(pal.bg_color.r) + int(pal.bg_color.g) + int(pal.bg_color.b)
		diff := fg - bg if fg > bg else bg - fg
		testing.expect(t, diff > 300, "fg/bg contrast too low")
	}
}

// LIB-CANDIDATE: this package must import only core:*.
//
// Paper palettes: a warm, ink-on-paper alternative to the cool grey-blue
// built-ins in theme.odin.
//
// Three rules shaped these values, and each exists because breaking it
// produced a visible defect during design:
//
//   - Accents are fills, never text. A muted highlighter yellow is the whole
//     point of the aesthetic, and it also fails WCAG AA against cream by a
//     wide margin. It therefore appears only as bg_selection and as tint
//     colors, never as an ink. contrast_test.odin enforces this: every reading
//     ink is checked against every surface, so an accent promoted to a text
//     role fails CI rather than shipping as an unreadable label.
//
//   - Surfaces are opaque. The other palettes make their windowed backgrounds
//     translucent so the macOS vibrancy layer shows through, which is right for
//     a frosted-glass look and wrong here: a blurred desktop behind cream reads
//     as dirty grey, not as paper. Both paper themes set identical windowed and
//     fullscreen values at full alpha, which disables the effect without
//     needing a special case in set_glass_fullscreen.
//
//   - Every reading pair clears full AA (4.5:1), not the 3.0:1 large-text floor
//     the dark and light palettes currently sit on. These are new palettes with
//     no installed base, so there is no migration cost to holding them to the
//     stricter bar from the start.
package ui

// THEME_PAPER is the light paper palette: warm cream stock, graphite body
// text, ink-blue headings and links, and a red margin rule.
//
// The neutrals carry a deliberate yellow-red bias rather than being pure greys.
// A neutral grey at the same luminance reads as newsprint or as a dimmed
// screen; the warmth is what makes it read as paper.
THEME_PAPER :: Theme {
	bg_app = Color{245, 240, 228, 255},
	bg_chat = Color{245, 240, 228, 255},
	bg_panel = Color{240, 234, 220, 255},
	bg_app_windowed = Color{245, 240, 228, 255},
	bg_chat_windowed = Color{245, 240, 228, 255},
	bg_panel_windowed = Color{240, 234, 220, 255},
	bg_app_fullscreen = Color{245, 240, 228, 255},
	bg_chat_fullscreen = Color{245, 240, 228, 255},
	bg_panel_fullscreen = Color{240, 234, 220, 255},
	bg_color = Color{245, 240, 228, 255},
	bg_secondary = Color{238, 232, 218, 255},
	bg_active = Color{226, 216, 192, 255},
	bg_hover = Color{236, 228, 208, 255},
	bg_input = Color{252, 249, 240, 255},
	bg_code = Color{236, 230, 215, 255},
	fg_primary = Color{44, 42, 38, 255},
	fg_secondary = Color{86, 80, 68, 255},
	fg_accent = Color{24, 66, 140, 255},
	fg_user = Color{34, 58, 120, 255},
	fg_assistant = Color{38, 84, 52, 255},
	fg_error = Color{150, 32, 28, 255},
	fg_success = Color{28, 92, 46, 255},
	fg_tool = Color{112, 76, 16, 255},
	fg_diff_remove = Color{146, 32, 28, 255},
	fg_diff_add = Color{28, 90, 46, 255},
	bg_diff_remove = Color{247, 226, 222, 255},
	bg_diff_add = Color{224, 240, 224, 255},
	fg_diff_gutter = Color{132, 124, 108, 255},
	border_color = Color{200, 190, 168, 255},
	border_subtle = Color{224, 216, 198, 255},
	badge_color = Color{186, 74, 58, 255},
	merge_link_color = Color{176, 92, 74, 255},
	button_bg = Color{32, 68, 132, 255},
	button_hover = Color{24, 52, 106, 255},
	button_text = Color{252, 249, 240, 255},
	bg_popup = Color{250, 246, 236, 255},
	fg_disabled = Color{158, 150, 134, 255},
	bg_plan_bar = Color{245, 232, 200, 255},
	fg_plan = Color{118, 76, 10, 255},
	fg_planning = Color{24, 66, 140, 255},
	bg_selection = Color{250, 226, 130, 255},
	bg_plan_title = Color{242, 228, 194, 255},
	bg_tool_card = Color{250, 246, 236, 255},
	bg_tool_card_hover = Color{243, 237, 224, 255},
	fg_heading = Color{26, 32, 52, 255},
	fg_bullet = Color{24, 66, 140, 255},
	fg_bold = Color{20, 18, 16, 255},
	fg_code_inline = Color{132, 66, 20, 255},
	bg_table_header = Color{234, 227, 210, 255},
	wave_color_a = Color{32, 68, 132, 255},
	wave_color_b = Color{140, 172, 220, 255},
	drop_zone_bg = Color{232, 238, 248, 235},
	drop_zone_border = Color{32, 68, 132, 255},
	fg_debug = Color{104, 52, 140, 255},
	bg_debug_title = Color{238, 230, 244, 255},
	fg_debug_changed = Color{150, 90, 12, 255},
	fg_debug_annotation = Color{96, 88, 74, 255},
	bg_chip = Color{232, 225, 208, 255},
	bg_chip_hover = Color{222, 213, 192, 255},
	bg_user_card = Color{234, 236, 246, 255},
	border_user_card = Color{192, 200, 224, 255},
	bg_band_error = Color{248, 228, 224, 255},
	fg_label = Color{96, 88, 74, 255},
	button_danger_bg = Color{150, 32, 28, 255},
	button_danger_hover = Color{122, 24, 20, 255},
	button_danger_fg = Color{252, 249, 240, 255},
	button_disabled_bg = Color{228, 222, 208, 255},
	button_pressed = Color{16, 38, 82, 255},
	surface_pressed = Color{214, 202, 176, 255},
	fg_accent_light = Color{44, 76, 150, 255},
	fg_muted_dim = Color{132, 124, 108, 255},
	modal_dim = Color{40, 34, 24, 110},
	focus_ring = Color{32, 68, 132, 235},
	// Paper casts a hard shadow rather than a soft one. The alpha is low
	// because a page lifted off a desk throws a narrow, pale shadow; the
	// heavier value the screen palettes use reads as a drop-shadow effect.
	shadow_color = Color{92, 78, 52, 70},
	// No gloss. A sheen is a glass and plastic cue; on paper it reads as a
	// rendering artifact, so both gradient stops are zeroed to disable it.
	button_primary_grad_top = Color{0, 0, 0, 0},
	button_primary_grad_bottom = Color{0, 0, 0, 0},
	paper_rule = Color{176, 196, 216, 150},
	paper_margin = Color{206, 122, 110, 190},
	highlighter = Color{250, 226, 130, 255},
	tape_color = Color{226, 216, 178, 190},
	ink_faded = Color{120, 112, 98, 255},
	fg_on_accent = Color{252, 249, 240, 255},
	caption_hover = Color{224, 214, 194, 255},
	caption_pressed = Color{208, 196, 170, 255},
	caption_close_hover = Color{196, 60, 48, 255},
	caption_close_pressed = Color{160, 40, 32, 255},
	spell_error = Color{176, 44, 38, 255},
	substrate = Substrate{kind = .Ruled, margin = true},
}

// THEME_PAPER_NIGHT is the dark counterpart: kraft and slate stock under warm
// off-white ink.
//
// It is not THEME_PAPER inverted. Inverting cream yields a muddy olive, and
// inverting saturated ink yields neon. The hues are held and the luminance
// relationships rebuilt, which is why the accents here are desaturated rather
// than simply lightened.
THEME_PAPER_NIGHT :: Theme {
	bg_app = Color{34, 32, 28, 255},
	bg_chat = Color{34, 32, 28, 255},
	bg_panel = Color{42, 39, 34, 255},
	bg_app_windowed = Color{34, 32, 28, 255},
	bg_chat_windowed = Color{34, 32, 28, 255},
	bg_panel_windowed = Color{42, 39, 34, 255},
	bg_app_fullscreen = Color{34, 32, 28, 255},
	bg_chat_fullscreen = Color{34, 32, 28, 255},
	bg_panel_fullscreen = Color{42, 39, 34, 255},
	bg_color = Color{34, 32, 28, 255},
	bg_secondary = Color{42, 39, 34, 255},
	bg_active = Color{66, 61, 53, 255},
	bg_hover = Color{58, 54, 47, 255},
	bg_input = Color{28, 26, 23, 255},
	bg_code = Color{38, 35, 31, 255},
	fg_primary = Color{232, 226, 212, 255},
	fg_secondary = Color{180, 172, 156, 255},
	fg_accent = Color{138, 178, 240, 255},
	fg_user = Color{158, 188, 244, 255},
	fg_assistant = Color{160, 206, 168, 255},
	fg_error = Color{240, 138, 130, 255},
	fg_success = Color{140, 206, 150, 255},
	fg_tool = Color{224, 188, 120, 255},
	fg_diff_remove = Color{244, 146, 138, 255},
	fg_diff_add = Color{146, 210, 155, 255},
	bg_diff_remove = Color{62, 36, 33, 255},
	bg_diff_add = Color{34, 56, 38, 255},
	fg_diff_gutter = Color{132, 125, 112, 255},
	border_color = Color{86, 79, 68, 255},
	border_subtle = Color{58, 54, 47, 255},
	badge_color = Color{224, 116, 100, 255},
	merge_link_color = Color{198, 132, 104, 255},
	button_bg = Color{92, 132, 204, 255},
	button_hover = Color{120, 158, 224, 255},
	button_text = Color{20, 20, 18, 255},
	bg_popup = Color{44, 41, 36, 255},
	fg_disabled = Color{112, 106, 95, 255},
	bg_plan_bar = Color{58, 48, 30, 255},
	fg_plan = Color{232, 192, 110, 255},
	fg_planning = Color{138, 178, 240, 255},
	bg_selection = Color{112, 96, 40, 255},
	bg_plan_title = Color{52, 44, 28, 255},
	bg_tool_card = Color{44, 41, 36, 255},
	bg_tool_card_hover = Color{52, 48, 42, 255},
	fg_heading = Color{246, 242, 232, 255},
	fg_bullet = Color{138, 178, 240, 255},
	fg_bold = Color{252, 250, 244, 255},
	fg_code_inline = Color{226, 176, 132, 255},
	bg_table_header = Color{50, 46, 41, 255},
	wave_color_a = Color{92, 132, 204, 255},
	wave_color_b = Color{160, 192, 246, 255},
	drop_zone_bg = Color{40, 50, 68, 235},
	drop_zone_border = Color{138, 178, 240, 255},
	fg_debug = Color{196, 156, 236, 255},
	bg_debug_title = Color{48, 40, 58, 255},
	fg_debug_changed = Color{232, 192, 110, 255},
	fg_debug_annotation = Color{164, 156, 140, 255},
	bg_chip = Color{54, 50, 44, 255},
	bg_chip_hover = Color{66, 61, 53, 255},
	bg_user_card = Color{40, 44, 58, 255},
	border_user_card = Color{70, 78, 100, 255},
	bg_band_error = Color{58, 36, 33, 255},
	fg_label = Color{164, 156, 140, 255},
	button_danger_bg = Color{214, 110, 100, 255},
	button_danger_hover = Color{236, 136, 124, 255},
	button_danger_fg = Color{24, 18, 16, 255},
	button_disabled_bg = Color{52, 49, 44, 255},
	button_pressed = Color{150, 182, 238, 255},
	surface_pressed = Color{80, 74, 64, 255},
	fg_accent_light = Color{160, 192, 246, 255},
	fg_muted_dim = Color{132, 125, 112, 255},
	modal_dim = Color{0, 0, 0, 150},
	focus_ring = Color{160, 192, 246, 235},
	shadow_color = Color{0, 0, 0, 120},
	button_primary_grad_top = Color{0, 0, 0, 0},
	button_primary_grad_bottom = Color{0, 0, 0, 0},
	paper_rule = Color{92, 104, 120, 130},
	paper_margin = Color{170, 96, 84, 170},
	// Dark enough that off-white ink still clears AA on top of it. A brighter
	// amber looks more like a marker but drops selected text to 2.6:1, which
	// makes the selection actively harder to read than the text around it.
	highlighter = Color{112, 96, 40, 255},
	tape_color = Color{92, 84, 68, 190},
	ink_faded = Color{150, 142, 128, 255},
	fg_on_accent = Color{20, 20, 18, 255},
	caption_hover = Color{62, 57, 50, 255},
	caption_pressed = Color{78, 72, 62, 255},
	caption_close_hover = Color{196, 60, 48, 255},
	caption_close_pressed = Color{160, 40, 32, 255},
	spell_error = Color{240, 138, 130, 255},
	substrate = Substrate{kind = .Ruled, margin = true},
}

// theme_paper returns the light paper palette.
theme_paper :: proc() -> Theme {
	return THEME_PAPER
}

// theme_paper_night returns the dark paper palette.
theme_paper_night :: proc() -> Theme {
	return THEME_PAPER_NIGHT
}

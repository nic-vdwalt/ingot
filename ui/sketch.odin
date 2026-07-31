// LIB-CANDIDATE: this package must import only core:*.
//
// Sketchbook palettes: toned drawing stock with saturated artist pigments.
//
// These replace an earlier pair of cream "notebook" palettes that read as
// stationery rather than as an artist's book. The difference is what the paper
// is *for*. Writing paper carries rules because text has to sit on something;
// drawing paper is blank and toned, and shows its grain instead. Everything
// here follows from that: no rules, no margin line, a warm ground rather than
// a white one, and accents drawn from pigment rather than from UI convention.
//
// Four rules shaped the values, and the first three are checked by tests:
//
//   - Every reading pair clears full WCAG AA (4.5:1). Toned stock compresses
//     contrast from both directions - it is neither white nor dark - so the
//     values were computed against every surface in the palette before being
//     written here, not chosen by eye and adjusted afterwards.
//
//   - The pigments are darkened from their true hues. Vermilion at full
//     saturation is 2.4:1 on kraft; the version here is 4.9:1. That is the
//     honest cost of putting saturated colour on a mid-toned ground, and it
//     is why "use the real pigment value" is not an option for anything that
//     carries text.
//
//   - Interaction states are palette roles, never arithmetic. A press on warm
//     stock darkens toward the tone; on grey it darkens toward neutral. No
//     single lighten/darken rule gets both right.
//
//   - Surfaces are opaque. The macOS vibrancy backdrop showing through toned
//     paper turns kraft into mud.
package ui

// THEME_SKETCH_WARM is toned kraft stock: warm tan ground, graphite line, and
// pigments that would sit in a watercolour box.
//
// The ground is the light end of the toned range. True mid-kraft carries
// graphite well enough but strangles the coloured pigments - ochre lands at
// 3.5:1 there, and ochre is the lightest pigment in the set, so it sets the
// floor for how dark the paper may be.
THEME_SKETCH_WARM :: Theme {
	bg_app = Color{230, 213, 186, 255},
	bg_chat = Color{230, 213, 186, 255},
	bg_panel = Color{222, 203, 173, 255},
	bg_app_windowed = Color{230, 213, 186, 255},
	bg_chat_windowed = Color{230, 213, 186, 255},
	bg_panel_windowed = Color{222, 203, 173, 255},
	bg_app_fullscreen = Color{230, 213, 186, 255},
	bg_chat_fullscreen = Color{230, 213, 186, 255},
	bg_panel_fullscreen = Color{222, 203, 173, 255},
	bg_color = Color{230, 213, 186, 255},
	bg_secondary = Color{222, 203, 173, 255},
	bg_active = Color{206, 183, 150, 255},
	bg_hover = Color{220, 200, 168, 255},
	bg_input = Color{240, 228, 208, 255},
	bg_code = Color{219, 199, 169, 255},
	fg_primary = Color{48, 44, 40, 255}, // graphite
	fg_secondary = Color{92, 84, 72, 255},
	fg_accent = Color{26, 42, 120, 255}, // ultramarine
	fg_user = Color{38, 52, 96, 255}, // indigo
	fg_assistant = Color{46, 84, 36, 255}, // sap green
	fg_error = Color{158, 38, 26, 255}, // vermilion
	fg_success = Color{16, 86, 70, 255}, // viridian
	fg_tool = Color{112, 62, 8, 255}, // yellow ochre
	fg_diff_remove = Color{150, 36, 24, 255},
	fg_diff_add = Color{20, 88, 44, 255},
	fg_diff_gutter = Color{140, 128, 108, 255},
	border_color = Color{176, 154, 122, 255},
	border_subtle = Color{210, 190, 158, 255},
	badge_color = Color{158, 38, 26, 255},
	merge_link_color = Color{122, 58, 32, 255},
	button_bg = Color{26, 42, 120, 255},
	button_hover = Color{18, 30, 96, 255},
	button_text = Color{242, 232, 214, 255},
	bg_popup = Color{238, 224, 202, 255},
	fg_disabled = Color{164, 150, 128, 255},
	bg_plan_bar = Color{232, 210, 164, 255},
	fg_plan = Color{120, 72, 10, 255},
	fg_planning = Color{26, 42, 120, 255},
	bg_selection = Color{242, 206, 116, 255},
	bg_plan_title = Color{228, 204, 158, 255},
	bg_tool_card = Color{236, 221, 198, 255},
	bg_tool_card_hover = Color{229, 212, 186, 255},
	fg_heading = Color{28, 26, 24, 255},
	fg_bullet = Color{26, 42, 120, 255},
	fg_bold = Color{20, 18, 16, 255},
	fg_code_inline = Color{122, 58, 32, 255}, // burnt sienna
	bg_table_header = Color{217, 197, 166, 255},
	wave_color_a = Color{26, 42, 120, 255},
	wave_color_b = Color{120, 146, 200, 255},
	drop_zone_bg = Color{212, 220, 240, 235},
	drop_zone_border = Color{26, 42, 120, 255},
	fg_debug = Color{92, 44, 120, 255},
	bg_debug_title = Color{224, 208, 226, 255},
	fg_debug_changed = Color{120, 72, 10, 255},
	fg_debug_annotation = Color{92, 84, 72, 255},
	bg_chip = Color{214, 194, 163, 255},
	bg_chip_hover = Color{204, 182, 148, 255},
	bg_user_card = Color{222, 218, 236, 255},
	border_user_card = Color{178, 172, 206, 255},
	bg_band_error = Color{238, 208, 196, 255},
	fg_label = Color{92, 82, 68, 255},
	button_danger_bg = Color{158, 38, 26, 255},
	button_danger_hover = Color{128, 28, 18, 255},
	button_danger_fg = Color{242, 232, 214, 255},
	button_disabled_bg = Color{218, 202, 176, 255},
	button_pressed = Color{14, 24, 78, 255},
	surface_pressed = Color{196, 172, 138, 255},
	fg_accent_light = Color{40, 60, 150, 255},
	fg_muted_dim = Color{140, 128, 108, 255},
	modal_dim = Color{44, 34, 20, 120},
	focus_ring = Color{26, 42, 120, 235},
	// Toned stock throws a warm, narrow shadow rather than the neutral grey a
	// screen palette uses.
	shadow_color = Color{92, 70, 40, 76},
	// No gloss: a sheen is a glass cue and reads as a rendering artifact on
	// paper.
	button_primary_grad_top = Color{0, 0, 0, 0},
	button_primary_grad_bottom = Color{0, 0, 0, 0},
	// No rules. A sketchbook page is blank; paper_rule stays zeroed so
	// draw_rule_lines short-circuits without needing a branch at the caller.
	paper_rule = Color{0, 0, 0, 0},
	paper_tooth = Color{176, 152, 116, 90},
	graphite = Color{86, 78, 66, 210},
	highlighter = Color{242, 206, 116, 255},
	tape_color = Color{226, 214, 186, 200},
	ink_faded = Color{128, 116, 98, 255},
	fg_on_accent = Color{242, 232, 214, 255},
	caption_hover = Color{214, 194, 163, 255},
	caption_pressed = Color{200, 178, 144, 255},
	caption_close_hover = Color{176, 44, 30, 255},
	caption_close_pressed = Color{140, 32, 22, 255},
	spell_error = Color{176, 44, 30, 255},
	substrate = Substrate{kind = .Tooth, margin_rule = false},
}

// THEME_SKETCH_GREY is the cool counterpart: neutral grey toned stock, the
// same pigment set shifted very slightly darker.
//
// Grey stock is marginally darker in luminance than the warm ground at the
// same apparent tone, so several pigments needed another step down to hold AA.
// Ochre was the binding constraint - it is the lightest pigment in the set and
// determined how light the ground had to be.
THEME_SKETCH_GREY :: Theme {
	bg_app = Color{206, 205, 200, 255},
	bg_chat = Color{206, 205, 200, 255},
	bg_panel = Color{197, 196, 190, 255},
	bg_app_windowed = Color{206, 205, 200, 255},
	bg_chat_windowed = Color{206, 205, 200, 255},
	bg_panel_windowed = Color{197, 196, 190, 255},
	bg_app_fullscreen = Color{206, 205, 200, 255},
	bg_chat_fullscreen = Color{206, 205, 200, 255},
	bg_panel_fullscreen = Color{197, 196, 190, 255},
	bg_color = Color{206, 205, 200, 255},
	bg_secondary = Color{197, 196, 190, 255},
	bg_active = Color{180, 179, 173, 255},
	bg_hover = Color{192, 191, 185, 255},
	bg_input = Color{218, 217, 213, 255},
	bg_code = Color{194, 193, 187, 255},
	fg_primary = Color{42, 42, 40, 255},
	fg_secondary = Color{78, 78, 74, 255},
	fg_accent = Color{26, 42, 120, 255},
	fg_user = Color{34, 48, 92, 255},
	fg_assistant = Color{40, 76, 32, 255},
	fg_error = Color{148, 34, 22, 255},
	fg_success = Color{12, 74, 58, 255},
	fg_tool = Color{98, 54, 6, 255},
	fg_diff_remove = Color{140, 32, 20, 255},
	fg_diff_add = Color{18, 80, 40, 255},
	fg_diff_gutter = Color{132, 132, 126, 255},
	border_color = Color{158, 157, 151, 255},
	border_subtle = Color{188, 187, 181, 255},
	badge_color = Color{148, 34, 22, 255},
	merge_link_color = Color{108, 50, 26, 255},
	button_bg = Color{26, 42, 120, 255},
	button_hover = Color{18, 30, 96, 255},
	button_text = Color{232, 231, 226, 255},
	bg_popup = Color{215, 214, 209, 255},
	fg_disabled = Color{156, 156, 150, 255},
	bg_plan_bar = Color{212, 206, 184, 255},
	fg_plan = Color{106, 64, 8, 255},
	fg_planning = Color{26, 42, 120, 255},
	bg_selection = Color{226, 206, 138, 255},
	bg_plan_title = Color{206, 200, 178, 255},
	bg_tool_card = Color{213, 212, 207, 255},
	bg_tool_card_hover = Color{204, 203, 198, 255},
	fg_heading = Color{24, 24, 22, 255},
	fg_bullet = Color{26, 42, 120, 255},
	fg_bold = Color{16, 16, 14, 255},
	fg_code_inline = Color{108, 50, 26, 255},
	bg_table_header = Color{193, 192, 186, 255},
	wave_color_a = Color{26, 42, 120, 255},
	wave_color_b = Color{112, 132, 186, 255},
	drop_zone_bg = Color{206, 212, 232, 235},
	drop_zone_border = Color{26, 42, 120, 255},
	fg_debug = Color{84, 40, 112, 255},
	bg_debug_title = Color{208, 200, 214, 255},
	fg_debug_changed = Color{106, 64, 8, 255},
	fg_debug_annotation = Color{78, 78, 74, 255},
	bg_chip = Color{190, 189, 183, 255},
	bg_chip_hover = Color{180, 179, 173, 255},
	bg_user_card = Color{204, 206, 220, 255},
	border_user_card = Color{164, 166, 190, 255},
	bg_band_error = Color{218, 200, 194, 255},
	fg_label = Color{78, 78, 74, 255},
	button_danger_bg = Color{148, 34, 22, 255},
	button_danger_hover = Color{120, 26, 16, 255},
	button_danger_fg = Color{232, 231, 226, 255},
	button_disabled_bg = Color{198, 197, 192, 255},
	button_pressed = Color{14, 24, 78, 255},
	surface_pressed = Color{170, 169, 163, 255},
	fg_accent_light = Color{38, 56, 142, 255},
	fg_muted_dim = Color{132, 132, 126, 255},
	modal_dim = Color{24, 24, 22, 130},
	focus_ring = Color{26, 42, 120, 235},
	shadow_color = Color{40, 40, 38, 82},
	button_primary_grad_top = Color{0, 0, 0, 0},
	button_primary_grad_bottom = Color{0, 0, 0, 0},
	paper_rule = Color{0, 0, 0, 0},
	paper_tooth = Color{150, 150, 144, 92},
	graphite = Color{78, 78, 74, 210},
	highlighter = Color{226, 206, 138, 255},
	tape_color = Color{212, 211, 204, 200},
	ink_faded = Color{120, 120, 114, 255},
	fg_on_accent = Color{232, 231, 226, 255},
	caption_hover = Color{190, 189, 183, 255},
	caption_pressed = Color{176, 175, 169, 255},
	caption_close_hover = Color{166, 40, 28, 255},
	caption_close_pressed = Color{132, 30, 20, 255},
	spell_error = Color{166, 40, 28, 255},
	substrate = Substrate{kind = .Tooth, margin_rule = false},
}

// theme_sketch_warm returns the toned kraft palette.
theme_sketch_warm :: proc() -> Theme {
	return THEME_SKETCH_WARM
}

// theme_sketch_grey returns the cool grey toned palette.
theme_sketch_grey :: proc() -> Theme {
	return THEME_SKETCH_GREY
}

// LIB-CANDIDATE: this package must import only core:*.
//
// Sketchbook palettes: toned drawing stock with saturated artist pigments.
//
// Writing paper carries rules because text has to sit on something; drawing
// paper is blank and toned, and shows its grain instead. Everything here
// follows from that: no rules, no margin line, a toned ground rather than a
// white one, and colour drawn from pigment rather than from UI convention.
//
// Five rules shaped the values, and the first four are checked by tests in
// sketch_test.odin:
//
//   - Every reading pair clears full WCAG AA (4.5:1), computed against every
//     surface in the palette before being written here rather than chosen by
//     eye and adjusted afterwards.
//
//   - The ground is genuinely toned: mid-value, carrying a real cast, and far
//     enough from both screen palettes that it cannot read as one of them
//     dimmed or lifted.
//
//   - Pigment and ink are separate. Ink is text and must clear AA; pigment is
//     paint and is bound by no text rule, so it stays saturated. This is the
//     split that lets the ground be properly toned - see the Pigment enum in
//     theme.odin for the circular constraint it replaced.
//
//   - Interaction states are palette roles, never arithmetic. A press on kraft
//     darkens toward the tone; on grey it darkens toward slate. No single
//     lighten/darken rule gets both right.
//
//   - Surfaces are opaque. The macOS vibrancy backdrop showing through toned
//     paper turns kraft into mud.
//
// The inks are deep - deeper than the pigments they are named for. That is the
// honest cost of a toned ground: a mid-value paper compresses contrast from
// both directions, so anything carrying text has to be pushed well below it.
// The saturation lives in the pigment table instead, where it is laid as paint
// and has no text to carry.
package ui

// THEME_SKETCH_WARM is toned kraft stock: warm tan ground, deep ink, and a
// pigment box of saturated colour.
//
// The ground measures chroma 74 and luminance 0.367 - close to real Canson
// kraft (183,150,105). An earlier version of this palette sat at chroma 44 and
// luminance 0.680, which measured only 1.32:1 from the light theme and read as
// light mode dimmed. It was pale because the pigments were doubling as text
// inks and the lightest of them, yellow ochre, could not clear AA on anything
// darker. Splitting pigment from ink removed that constraint entirely.
THEME_SKETCH_WARM :: Theme {
	bg_app = Color{190, 158, 116, 255},
	bg_chat = Color{190, 158, 116, 255},
	bg_panel = Color{179, 149, 109, 255},
	bg_app_windowed = Color{190, 158, 116, 255},
	bg_chat_windowed = Color{190, 158, 116, 255},
	bg_panel_windowed = Color{179, 149, 109, 255},
	bg_app_fullscreen = Color{190, 158, 116, 255},
	bg_chat_fullscreen = Color{190, 158, 116, 255},
	bg_panel_fullscreen = Color{179, 149, 109, 255},
	bg_color = Color{190, 158, 116, 255},
	bg_secondary = Color{179, 149, 109, 255},
	bg_active = Color{167, 139, 102, 255},
	bg_hover = Color{180, 150, 110, 255},
	bg_input = Color{198, 170, 133, 255},
	bg_code = Color{171, 142, 104, 255},
	fg_primary = Color{38, 34, 30, 255},
	fg_secondary = Color{48, 42, 33, 255},
	fg_accent = Color{20, 30, 88, 255},
	fg_user = Color{24, 36, 72, 255},
	fg_assistant = Color{26, 48, 18, 255},
	fg_error = Color{88, 17, 12, 255},
	fg_success = Color{8, 48, 36, 255},
	fg_tool = Color{64, 37, 6, 255},
	fg_diff_remove = Color{85, 17, 12, 255},
	fg_diff_add = Color{10, 49, 24, 255},
	fg_diff_gutter = Color{122, 101, 74, 255},
	border_color = Color{148, 123, 90, 255},
	border_subtle = Color{175, 145, 107, 255},
	badge_color = Color{88, 17, 12, 255},
	merge_link_color = Color{69, 30, 16, 255},
	button_bg = Color{20, 30, 88, 255},
	button_hover = Color{14, 22, 68, 255},
	button_text = Color{246, 241, 236, 255},
	bg_popup = Color{195, 165, 126, 255},
	fg_disabled = Color{133, 111, 81, 255},
	bg_plan_bar = Color{196, 162, 106, 255},
	fg_plan = Color{64, 37, 6, 255},
	fg_planning = Color{20, 30, 88, 255},
	bg_selection = Color{222, 178, 74, 255},
	bg_plan_title = Color{188, 155, 102, 255},
	bg_tool_card = Color{193, 163, 123, 255},
	bg_tool_card_hover = Color{185, 154, 114, 255},
	fg_heading = Color{22, 20, 18, 255},
	fg_bullet = Color{20, 30, 88, 255},
	fg_bold = Color{14, 12, 10, 255},
	fg_code_inline = Color{69, 30, 16, 255},
	bg_table_header = Color{177, 147, 108, 255},
	wave_color_a = Color{20, 30, 88, 255},
	wave_color_b = Color{50, 62, 180, 255},
	drop_zone_bg = Color{174, 176, 206, 235},
	drop_zone_border = Color{20, 30, 88, 255},
	fg_debug = Color{62, 24, 82, 255},
	bg_debug_title = Color{186, 158, 138, 255},
	fg_debug_changed = Color{64, 37, 6, 255},
	fg_debug_annotation = Color{48, 42, 33, 255},
	bg_chip = Color{173, 144, 106, 255},
	bg_chip_hover = Color{164, 136, 100, 255},
	bg_user_card = Color{180, 160, 148, 255},
	border_user_card = Color{150, 128, 118, 255},
	bg_band_error = Color{196, 148, 120, 255},
	fg_label = Color{48, 42, 33, 255},
	button_danger_bg = Color{88, 17, 12, 255},
	button_danger_hover = Color{66, 12, 8, 255},
	button_danger_fg = Color{246, 241, 236, 255},
	button_disabled_bg = Color{172, 145, 110, 255},
	button_pressed = Color{10, 16, 52, 255},
	surface_pressed = Color{152, 126, 93, 255},
	fg_accent_light = Color{28, 39, 96, 255},
	fg_muted_dim = Color{114, 95, 70, 255},
	modal_dim = Color{40, 30, 16, 130},
	focus_ring = Color{20, 30, 88, 235},
	// Toned stock throws a warm, narrow shadow rather than the neutral grey a
	// screen palette uses.
	shadow_color = Color{78, 56, 30, 90},
	// No gloss: a sheen is a glass cue and reads as an artifact on paper.
	button_primary_grad_top = Color{0, 0, 0, 0},
	button_primary_grad_bottom = Color{0, 0, 0, 0},
	// No rules. A sketchbook page is blank; paper_rule stays zeroed so
	// draw_rule_lines short-circuits without a branch at the caller.
	paper_rule = Color{0, 0, 0, 0},
	paper_tooth = Color{156, 130, 95, 110},
	graphite = Color{80, 66, 49, 220},
	// Chalk is the light direction: white gouache above the ground, where ink
	// works below it. On this mid ground it is a highlight material and never
	// a text colour - it measures about 2.3:1 here, which is a lit edge rather
	// than something to read.
	chalk = Color{246, 241, 236, 255},
	highlighter = Color{222, 178, 74, 255},
	tape_color = Color{206, 186, 152, 205},
	ink_faded = Color{110, 92, 68, 255},
	fg_on_accent = Color{246, 241, 236, 255},
	caption_hover = Color{173, 144, 106, 255},
	caption_pressed = Color{158, 131, 96, 255},
	caption_close_hover = Color{146, 30, 20, 255},
	caption_close_pressed = Color{112, 22, 15, 255},
	spell_error = Color{146, 30, 20, 255},
	// Pigments: saturated, because they carry no text. Each is far more
	// chromatic than the ink of the same name, which is the invariant
	// sketch_test.odin checks - if the two ever converge, the split has been
	// undone and the ground will be forced pale again.
	pigments = {
		.Accent  = Color{50, 62, 180, 255}, // ultramarine
		.Danger  = Color{206, 58, 42, 255}, // vermilion
		.Success = Color{40, 120, 96, 255}, // viridian
		.Tool    = Color{206, 132, 32, 255}, // yellow ochre
		.Earth   = Color{160, 72, 36, 255}, // burnt sienna
		.Leaf    = Color{96, 132, 48, 255}, // sap green
	},
	substrate = Substrate{kind = .Tooth, margin_rule = false},
}

// THEME_SKETCH_GREY is cool toned stock: a blue-grey ground with the same
// pigment box.
//
// The cast is the point. An earlier version measured chroma 6 - dead neutral -
// which reads as interface grey however the luminance is tuned, because the
// eye has no colour cue to tell it this is paper. This ground carries chroma
// 18, enough to read as slate-toned stock rather than as a dimmed screen.
//
// It sits slightly lighter than the warm ground (luminance 0.359 against
// 0.367 is near-identical, but grey has no warm channel to carry luminance),
// which leaves the deep inks room to clear AA without collapsing to black.
THEME_SKETCH_GREY :: Theme {
	bg_app = Color{150, 164, 168, 255},
	bg_chat = Color{150, 164, 168, 255},
	bg_panel = Color{141, 154, 158, 255},
	bg_app_windowed = Color{150, 164, 168, 255},
	bg_chat_windowed = Color{150, 164, 168, 255},
	bg_panel_windowed = Color{141, 154, 158, 255},
	bg_app_fullscreen = Color{150, 164, 168, 255},
	bg_chat_fullscreen = Color{150, 164, 168, 255},
	bg_panel_fullscreen = Color{141, 154, 158, 255},
	bg_color = Color{150, 164, 168, 255},
	bg_secondary = Color{141, 154, 158, 255},
	bg_active = Color{132, 144, 148, 255},
	bg_hover = Color{142, 156, 160, 255},
	bg_input = Color{163, 175, 178, 255},
	bg_code = Color{135, 148, 151, 255},
	fg_primary = Color{38, 34, 30, 255},
	fg_secondary = Color{48, 42, 33, 255},
	fg_accent = Color{20, 30, 88, 255},
	fg_user = Color{24, 36, 72, 255},
	fg_assistant = Color{26, 48, 18, 255},
	fg_error = Color{81, 16, 11, 255},
	fg_success = Color{8, 48, 36, 255},
	fg_tool = Color{64, 37, 6, 255},
	fg_diff_remove = Color{85, 17, 12, 255},
	fg_diff_add = Color{10, 49, 24, 255},
	fg_diff_gutter = Color{96, 105, 108, 255},
	border_color = Color{117, 128, 131, 255},
	border_subtle = Color{138, 151, 155, 255},
	badge_color = Color{81, 16, 11, 255},
	merge_link_color = Color{69, 30, 16, 255},
	button_bg = Color{20, 30, 88, 255},
	button_hover = Color{14, 22, 68, 255},
	button_text = Color{240, 242, 243, 255},
	bg_popup = Color{157, 170, 174, 255},
	fg_disabled = Color{105, 115, 118, 255},
	bg_plan_bar = Color{164, 160, 132, 255},
	fg_plan = Color{64, 37, 6, 255},
	fg_planning = Color{20, 30, 88, 255},
	bg_selection = Color{206, 186, 106, 255},
	bg_plan_title = Color{156, 152, 126, 255},
	bg_tool_card = Color{155, 169, 172, 255},
	bg_tool_card_hover = Color{147, 160, 164, 255},
	fg_heading = Color{22, 20, 18, 255},
	fg_bullet = Color{20, 30, 88, 255},
	fg_bold = Color{14, 12, 10, 255},
	fg_code_inline = Color{69, 30, 16, 255},
	bg_table_header = Color{140, 153, 156, 255},
	wave_color_a = Color{20, 30, 88, 255},
	wave_color_b = Color{50, 62, 180, 255},
	drop_zone_bg = Color{158, 168, 202, 235},
	drop_zone_border = Color{20, 30, 88, 255},
	fg_debug = Color{62, 24, 82, 255},
	bg_debug_title = Color{152, 156, 174, 255},
	fg_debug_changed = Color{64, 37, 6, 255},
	fg_debug_annotation = Color{48, 42, 33, 255},
	bg_chip = Color{136, 149, 153, 255},
	bg_chip_hover = Color{128, 140, 144, 255},
	bg_user_card = Color{148, 158, 178, 255},
	border_user_card = Color{124, 134, 156, 255},
	bg_band_error = Color{168, 146, 144, 255},
	fg_label = Color{48, 42, 33, 255},
	button_danger_bg = Color{81, 16, 11, 255},
	button_danger_hover = Color{60, 11, 7, 255},
	button_danger_fg = Color{240, 242, 243, 255},
	button_disabled_bg = Color{144, 157, 161, 255},
	button_pressed = Color{10, 16, 52, 255},
	surface_pressed = Color{120, 131, 134, 255},
	fg_accent_light = Color{26, 36, 88, 255},
	fg_muted_dim = Color{90, 98, 101, 255},
	modal_dim = Color{18, 22, 24, 140},
	focus_ring = Color{20, 30, 88, 235},
	shadow_color = Color{30, 38, 42, 92},
	button_primary_grad_top = Color{0, 0, 0, 0},
	button_primary_grad_bottom = Color{0, 0, 0, 0},
	paper_rule = Color{0, 0, 0, 0},
	paper_tooth = Color{123, 134, 138, 110},
	graphite = Color{63, 69, 71, 220},
	chalk = Color{240, 242, 243, 255},
	highlighter = Color{206, 186, 106, 255},
	tape_color = Color{196, 202, 204, 205},
	ink_faded = Color{88, 96, 99, 255},
	fg_on_accent = Color{240, 242, 243, 255},
	caption_hover = Color{136, 149, 153, 255},
	caption_pressed = Color{124, 136, 139, 255},
	caption_close_hover = Color{138, 28, 19, 255},
	caption_close_pressed = Color{104, 20, 14, 255},
	spell_error = Color{138, 28, 19, 255},
	pigments = {
		.Accent = Color{50, 62, 180, 255},
		.Danger = Color{206, 58, 42, 255},
		.Success = Color{40, 120, 96, 255},
		.Tool = Color{206, 132, 32, 255},
		.Earth = Color{160, 72, 36, 255},
		.Leaf = Color{96, 132, 48, 255},
	},
	substrate = Substrate{kind = .Tooth, margin_rule = false},
}

// theme_sketch_warm returns the toned kraft palette.
theme_sketch_warm :: proc() -> Theme {
	return THEME_SKETCH_WARM
}

// theme_sketch_grey returns the cool toned palette.
theme_sketch_grey :: proc() -> Theme {
	return THEME_SKETCH_GREY
}

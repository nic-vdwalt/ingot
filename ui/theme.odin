// LIB-CANDIDATE: this package must import only core:*.
// Never import app packages - destined for a standalone Odin GUI library.
// Merged from openalloy/alloy (full app palette + macOS glass) plus
// ingot-only re-theme constants preserved for other consumers.
//
// Colors live in the runtime Theme struct (module var `theme`) so the palette
// can be swapped at runtime (dark/light/user themes) via set_theme().
// Non-color metrics (pixel dimensions, ratios, limits) remain module-level
// variables rescaled by set_ui_scale() in scale.odin.
package ui

import "core:math"


// GLASS_ENABLED is true on macOS, where window_style_darwin.odin installs an
// NSVisualEffectView vibrancy backdrop behind the GL view. Large surface fills
// become translucent so the frosted blur shows through; other platforms keep
// fully opaque fills.
GLASS_ENABLED :: ODIN_OS == .Darwin

// Theme holds every palette color. Callers read fields through the module
// var `theme`; swap the whole palette with set_theme().
Theme :: struct {
	// Glass surfaces. bg_app/bg_chat/bg_panel are the *active* values drawn
	// each frame; the windowed/fullscreen variants are the sources that
	// set_glass_fullscreen() copies from (identical on non-glass platforms).
	bg_app:                     Color,
	bg_chat:                    Color,
	bg_panel:                   Color,
	bg_app_windowed:            Color,
	bg_chat_windowed:           Color,
	bg_panel_windowed:          Color,
	bg_app_fullscreen:          Color,
	bg_chat_fullscreen:         Color,
	bg_panel_fullscreen:        Color,

	// Core palette.
	bg_color:                   Color, // App background
	bg_secondary:               Color, // Slightly offset from background
	bg_active:                  Color, // Active tab/selection
	bg_hover:                   Color, // Hover state
	bg_input:                   Color, // Input field background
	bg_code:                    Color, // Code block background
	fg_primary:                 Color, // Primary text
	fg_secondary:               Color, // Secondary/muted text
	fg_accent:                  Color, // Accent (links, active)
	fg_user:                    Color, // User message
	fg_assistant:               Color, // Assistant message
	fg_error:                   Color, // Error text
	fg_success:                 Color, // Success text
	fg_tool:                    Color, // Tool activity
	fg_diff_remove:             Color, // Diff: removed lines
	fg_diff_add:                Color, // Diff: added lines
	bg_diff_remove:             Color, // Diff: removed cell background
	bg_diff_add:                Color, // Diff: added cell background
	fg_diff_gutter:             Color, // Diff: line-number gutter
	border_color:               Color, // Borders
	border_subtle:              Color, // Hairline borders (cards, dividers)
	badge_color:                Color, // Unread badge
	merge_link_color:           Color, // Joined/merged tab-group link
	button_bg:                  Color, // Button background
	button_hover:               Color, // Button hover
	button_text:                Color, // Button text
	bg_popup:                   Color, // Command menu popup background
	fg_disabled:                Color, // Disabled command text
	bg_plan_bar:                Color, // Plan mode bar background
	fg_plan:                    Color, // Plan mode text/accent
	fg_planning:                Color, // Planning mode accent
	bg_selection:               Color, // Text selection highlight
	bg_plan_title:              Color, // Plan sidebar title card background

	// Tool card styling.
	bg_tool_card:               Color, // Card background
	bg_tool_card_hover:         Color, // Card hover state
	fg_heading:                 Color, // Heading text
	fg_bullet:                  Color, // Bullet point dot
	fg_bold:                    Color, // Bold text
	fg_code_inline:             Color, // Inline `code` text (non-file)
	bg_table_header:            Color, // Table header row background

	// Agent-busy wave bar.
	wave_color_a:               Color,
	wave_color_b:               Color,

	// Drag-and-drop drop zone.
	drop_zone_bg:               Color,
	drop_zone_border:           Color,

	// Debug watch sidebar.
	fg_debug:                   Color, // Accent for debug panel
	bg_debug_title:             Color, // Debug title card background
	fg_debug_changed:           Color, // Changed values
	fg_debug_annotation:        Color, // Annotations

	// Attachment chips.
	bg_chip:                    Color,
	bg_chip_hover:              Color,

	// Flat chat message styling.
	bg_user_card:               Color, // Compact user prompt card
	border_user_card:           Color, // 1px card border
	bg_band_error:              Color, // Error message tint band
	fg_label:                   Color, // Small uppercase role/section labels

	// Buttons (danger / disabled / pressed) and misc.
	button_danger_bg:           Color,
	button_danger_hover:        Color,
	button_danger_fg:           Color,
	button_disabled_bg:         Color,
	button_pressed:             Color,

	// surface_pressed is the generic press tint for every surface that is not
	// the primary button: rows, tabs, menu items, chips, cards. Before it
	// existed only the primary button had a pressed color, so every other
	// surface stayed visually identical between "hovered" and "being clicked".
	// It is a palette role rather than an arithmetic darkening of bg_hover
	// because a light theme must press *darker* and a dark theme *lighter*,
	// and no single arithmetic rule gets both right.
	surface_pressed:            Color,
	fg_accent_light:            Color, // Lighter accent for text on dark
	fg_muted_dim:               Color, // Dimmed text; Ink.Muted only, not disabled state
	modal_dim:                  Color, // Backdrop dim behind modals
	focus_ring:                 Color, // Keyboard focus-visible ring around widgets

	// Depth & flare (additive fields; zero alpha disables the effect).
	shadow_color:               Color, // Soft drop-shadow tint under cards
	button_primary_grad_top:    Color, // Gloss sheen on primary buttons (top)
	button_primary_grad_bottom: Color, // Gloss fade-out color (bottom)

	// Paper materials. A palette that leaves these zeroed simply draws no
	// paper: material.odin treats a zero-alpha color as "effect disabled", so
	// the screen palettes need no special case to opt out.
	paper_rule:                 Color, // Ruled notebook line
	paper_tooth:                Color, // Sketchbook paper grain flecks
	graphite:                   Color, // Pencil: heading underlines, captions
	chalk:                      Color, // White gouache: the light direction
	highlighter:                Color, // Marker swipe behind selected content
	tape_color:                 Color, // Tape strip across a corner
	ink_faded:                  Color, // Ink that has soaked or dried lighter

	// Pigments are paint, not text. See the Pigment enum for why they are a
	// separate table from the fg_* inks rather than the same values reused.
	pigments:                   [Pigment]Color,

	// Roles that resolve a state or placement the palette previously left to
	// each widget to guess.
	fg_on_accent:               Color, // Text drawn on any accent fill
	caption_hover:              Color, // Window caption button hover
	caption_pressed:            Color, // Window caption button press
	caption_close_hover:        Color, // Close button hover (destructive)
	caption_close_pressed:      Color, // Close button press
	spell_error:                Color, // Spellcheck squiggle

	// Substrate selects the page texture drawn behind panels and cards.
	substrate:                  Substrate,

	// Accessibility. reduced_motion snaps animations (hover ease, caret
	// blink) to their final state for vestibular/motion-sensitive users.
	reduced_motion:             bool,
}

// Substrate_Kind names the page texture drawn behind a surface.
//
// Dots are deliberately not a whole-page option even though the enum permits
// asking: a dot grid is quadratic in the area it covers and would exceed the
// per-frame paint budget several times over at 4K. draw_dot_grid asserts the
// bound, and dot_grid_fits lets a caller check before asking. Tooth carries
// its own hard count for the same reason.
Substrate_Kind :: enum u8 {
	None,
	Ruled,
	Grid,
	Dots,
	Tooth,
}

Substrate :: struct {
	kind:        Substrate_Kind,
	// Draw the vertical margin rule. Separate from the body indent because a
	// sketchbook wants the reserved space without the exercise-book line, and
	// a caller cannot ask for that if one flag stands for both. The indent
	// follows from kind != .None; this controls only whether a line is drawn.
	margin_rule: bool,
}

// Glass surface source values per theme. On glass platforms (macOS) the
// windowed variants are translucent so the vibrancy backdrop shows through;
// fullscreen variants are near-opaque so the fallback doesn't bleed. On
// non-glass platforms both variants equal the opaque surface colors.
when GLASS_ENABLED {
	@(private = "file")
	DARK_BG_APP_WINDOWED :: Color{30, 30, 30, 162}
	@(private = "file")
	DARK_BG_CHAT_WINDOWED :: Color{28, 28, 30, 207}
	@(private = "file")
	DARK_BG_PANEL_WINDOWED :: Color{36, 36, 40, 212}
	@(private = "file")
	DARK_BG_APP_FULLSCREEN :: Color{30, 30, 30, 245}
	@(private = "file")
	DARK_BG_CHAT_FULLSCREEN :: Color{28, 28, 30, 250}
	@(private = "file")
	DARK_BG_PANEL_FULLSCREEN :: Color{36, 36, 40, 250}
	@(private = "file")
	LIGHT_BG_APP_WINDOWED :: Color{245, 245, 247, 170}
	@(private = "file")
	LIGHT_BG_CHAT_WINDOWED :: Color{242, 242, 246, 210}
	@(private = "file")
	LIGHT_BG_PANEL_WINDOWED :: Color{236, 236, 242, 215}
	@(private = "file")
	LIGHT_BG_APP_FULLSCREEN :: Color{245, 245, 247, 247}
	@(private = "file")
	LIGHT_BG_CHAT_FULLSCREEN :: Color{242, 242, 246, 250}
	@(private = "file")
	LIGHT_BG_PANEL_FULLSCREEN :: Color{236, 236, 242, 250}
} else {
	@(private = "file")
	DARK_BG_APP_WINDOWED :: Color{30, 30, 30, 255}
	@(private = "file")
	DARK_BG_CHAT_WINDOWED :: Color{30, 30, 30, 255}
	@(private = "file")
	DARK_BG_PANEL_WINDOWED :: Color{40, 40, 40, 255}
	@(private = "file")
	DARK_BG_APP_FULLSCREEN :: Color{30, 30, 30, 255}
	@(private = "file")
	DARK_BG_CHAT_FULLSCREEN :: Color{30, 30, 30, 255}
	@(private = "file")
	DARK_BG_PANEL_FULLSCREEN :: Color{40, 40, 40, 255}
	@(private = "file")
	LIGHT_BG_APP_WINDOWED :: Color{245, 245, 247, 255}
	@(private = "file")
	LIGHT_BG_CHAT_WINDOWED :: Color{245, 245, 247, 255}
	@(private = "file")
	LIGHT_BG_PANEL_WINDOWED :: Color{236, 236, 242, 255}
	@(private = "file")
	LIGHT_BG_APP_FULLSCREEN :: Color{245, 245, 247, 255}
	@(private = "file")
	LIGHT_BG_CHAT_FULLSCREEN :: Color{245, 245, 247, 255}
	@(private = "file")
	LIGHT_BG_PANEL_FULLSCREEN :: Color{236, 236, 242, 255}
}

// THEME_DARK preserves the original compile-time palette values exactly.
THEME_DARK :: Theme {
	bg_app = DARK_BG_APP_WINDOWED,
	bg_chat = DARK_BG_CHAT_WINDOWED,
	bg_panel = DARK_BG_PANEL_WINDOWED,
	bg_app_windowed = DARK_BG_APP_WINDOWED,
	bg_chat_windowed = DARK_BG_CHAT_WINDOWED,
	bg_panel_windowed = DARK_BG_PANEL_WINDOWED,
	bg_app_fullscreen = DARK_BG_APP_FULLSCREEN,
	bg_chat_fullscreen = DARK_BG_CHAT_FULLSCREEN,
	bg_panel_fullscreen = DARK_BG_PANEL_FULLSCREEN,
	bg_color = Color{30, 30, 30, 255},
	bg_secondary = Color{40, 40, 40, 255},
	bg_active = Color{50, 50, 60, 255},
	bg_hover = Color{55, 55, 65, 255},
	bg_input = Color{45, 45, 50, 255},
	bg_code = Color{35, 35, 40, 255},
	fg_primary = Color{220, 220, 220, 255},
	fg_secondary = Color{160, 160, 170, 255},
	fg_accent = Color{100, 160, 255, 255},
	fg_user = Color{180, 200, 255, 255},
	fg_assistant = Color{200, 220, 200, 255},
	fg_error = Color{255, 120, 120, 255},
	fg_success = Color{120, 220, 120, 255},
	fg_tool = Color{200, 180, 120, 255},
	fg_diff_remove = Color{255, 140, 140, 255},
	fg_diff_add = Color{140, 230, 140, 255},
	bg_diff_remove = Color{60, 30, 30, 255},
	bg_diff_add = Color{28, 50, 30, 255},
	fg_diff_gutter = Color{110, 110, 120, 255},
	border_color = Color{70, 70, 80, 255},
	border_subtle = Color{52, 52, 60, 255},
	badge_color = Color{255, 100, 100, 255},
	merge_link_color = Color{70, 110, 170, 255},
	button_bg = Color{60, 100, 180, 255},
	button_hover = Color{70, 120, 200, 255},
	button_text = Color{255, 255, 255, 255},
	bg_popup = Color{35, 35, 42, 255},
	fg_disabled = Color{90, 90, 100, 255},
	bg_plan_bar = Color{60, 50, 20, 255},
	fg_plan = Color{255, 200, 80, 255},
	fg_planning = Color{110, 170, 240, 255},
	bg_selection = Color{60, 80, 130, 255},
	bg_plan_title = Color{48, 42, 24, 255},
	bg_tool_card = Color{38, 38, 45, 255},
	bg_tool_card_hover = Color{45, 45, 55, 255},
	fg_heading = Color{230, 230, 240, 255},
	fg_bullet = Color{140, 160, 200, 255},
	fg_bold = Color{255, 255, 255, 255},
	fg_code_inline = Color{214, 182, 150, 255},
	bg_table_header = Color{45, 45, 52, 255},
	wave_color_a = Color{30, 95, 138, 255},
	wave_color_b = Color{126, 206, 240, 255},
	drop_zone_bg = Color{45, 55, 75, 235},
	drop_zone_border = Color{100, 160, 255, 255},
	fg_debug = Color{180, 140, 255, 255},
	bg_debug_title = Color{40, 32, 52, 255},
	fg_debug_changed = Color{255, 180, 80, 255},
	fg_debug_annotation = Color{140, 160, 180, 255},
	bg_chip = Color{55, 60, 72, 255},
	bg_chip_hover = Color{70, 76, 92, 255},
	bg_user_card = Color{44, 52, 74, 255},
	border_user_card = Color{78, 96, 140, 255},
	bg_band_error = Color{52, 34, 34, 255},
	fg_label = Color{130, 135, 150, 255},
	button_danger_bg = Color{62, 36, 36, 255},
	button_danger_hover = Color{80, 35, 35, 255},
	button_danger_fg = Color{255, 180, 180, 255},
	button_disabled_bg = Color{47, 49, 54, 255},
	button_pressed = Color{58, 67, 160, 255},
	surface_pressed = Color{68, 68, 80, 255},
	fg_accent_light = Color{129, 140, 248, 255},
	fg_muted_dim = Color{110, 115, 122, 255},
	modal_dim = Color{0, 0, 0, 140},
	focus_ring = Color{129, 160, 255, 220},
	shadow_color = Color{0, 0, 0, 120},
	button_primary_grad_top = Color{255, 255, 255, 20},
	button_primary_grad_bottom = Color{0, 0, 0, 0},
	// No paper materials: this is a screen palette, and a zero-alpha color
	// disables the effect in material.odin without a branch there.
	paper_rule = Color{0, 0, 0, 0},
	paper_tooth = Color{0, 0, 0, 0},
	graphite = Color{0, 0, 0, 0},
	highlighter = Color{0, 0, 0, 0},
	tape_color = Color{0, 0, 0, 0},
	ink_faded = Color{150, 150, 160, 255},
	fg_on_accent = Color{255, 255, 255, 255},
	caption_hover = Color{70, 70, 82, 255},
	caption_pressed = Color{88, 88, 104, 255},
	caption_close_hover = Color{232, 64, 52, 255},
	caption_close_pressed = Color{180, 40, 32, 255},
	spell_error = Color{255, 120, 120, 255},
	substrate = Substrate{kind = .None, margin_rule = false},
}

// THEME_LIGHT is a light counterpart tuned for equivalent contrast roles.
THEME_LIGHT :: Theme {
	bg_app = LIGHT_BG_APP_WINDOWED,
	bg_chat = LIGHT_BG_CHAT_WINDOWED,
	bg_panel = LIGHT_BG_PANEL_WINDOWED,
	bg_app_windowed = LIGHT_BG_APP_WINDOWED,
	bg_chat_windowed = LIGHT_BG_CHAT_WINDOWED,
	bg_panel_windowed = LIGHT_BG_PANEL_WINDOWED,
	bg_app_fullscreen = LIGHT_BG_APP_FULLSCREEN,
	bg_chat_fullscreen = LIGHT_BG_CHAT_FULLSCREEN,
	bg_panel_fullscreen = LIGHT_BG_PANEL_FULLSCREEN,
	bg_color = Color{245, 245, 247, 255},
	bg_secondary = Color{235, 235, 238, 255},
	bg_active = Color{220, 224, 235, 255},
	bg_hover = Color{214, 218, 228, 255},
	bg_input = Color{255, 255, 255, 255},
	bg_code = Color{238, 238, 242, 255},
	fg_primary = Color{35, 35, 40, 255},
	fg_secondary = Color{95, 95, 105, 255},
	fg_accent = Color{20, 90, 200, 255},
	fg_user = Color{40, 70, 140, 255},
	fg_assistant = Color{40, 90, 50, 255},
	fg_error = Color{190, 40, 40, 255},
	fg_success = Color{30, 140, 60, 255},
	fg_tool = Color{140, 110, 40, 255},
	fg_diff_remove = Color{180, 40, 40, 255},
	fg_diff_add = Color{30, 130, 50, 255},
	bg_diff_remove = Color{250, 225, 225, 255},
	bg_diff_add = Color{223, 245, 225, 255},
	fg_diff_gutter = Color{140, 140, 150, 255},
	border_color = Color{200, 200, 210, 255},
	border_subtle = Color{222, 222, 228, 255},
	badge_color = Color{220, 60, 60, 255},
	merge_link_color = Color{80, 120, 180, 255},
	button_bg = Color{55, 110, 210, 255},
	button_hover = Color{45, 95, 190, 255},
	button_text = Color{255, 255, 255, 255},
	bg_popup = Color{250, 250, 252, 255},
	fg_disabled = Color{170, 170, 180, 255},
	bg_plan_bar = Color{250, 238, 205, 255},
	fg_plan = Color{150, 110, 10, 255},
	fg_planning = Color{40, 110, 200, 255},
	bg_selection = Color{180, 205, 245, 255},
	bg_plan_title = Color{247, 240, 215, 255},
	bg_tool_card = Color{240, 240, 244, 255},
	bg_tool_card_hover = Color{232, 232, 238, 255},
	fg_heading = Color{25, 25, 35, 255},
	fg_bullet = Color{80, 110, 170, 255},
	fg_bold = Color{0, 0, 0, 255},
	fg_code_inline = Color{150, 90, 30, 255},
	bg_table_header = Color{232, 232, 238, 255},
	wave_color_a = Color{30, 95, 138, 255},
	wave_color_b = Color{90, 170, 220, 255},
	drop_zone_bg = Color{215, 228, 248, 235},
	drop_zone_border = Color{20, 90, 200, 255},
	fg_debug = Color{120, 70, 200, 255},
	bg_debug_title = Color{238, 230, 248, 255},
	fg_debug_changed = Color{190, 120, 20, 255},
	fg_debug_annotation = Color{110, 130, 150, 255},
	bg_chip = Color{225, 229, 238, 255},
	bg_chip_hover = Color{212, 218, 232, 255},
	bg_user_card = Color{225, 232, 248, 255},
	border_user_card = Color{170, 190, 225, 255},
	bg_band_error = Color{250, 228, 228, 255},
	fg_label = Color{110, 115, 130, 255},
	button_danger_bg = Color{235, 205, 205, 255},
	button_danger_hover = Color{225, 185, 185, 255},
	button_danger_fg = Color{160, 40, 40, 255},
	button_disabled_bg = Color{228, 228, 232, 255},
	button_pressed = Color{120, 135, 235, 255},
	surface_pressed = Color{196, 202, 214, 255},
	fg_accent_light = Color{80, 95, 220, 255},
	fg_muted_dim = Color{150, 155, 165, 255},
	modal_dim = Color{0, 0, 0, 90},
	focus_ring = Color{30, 100, 220, 220},
	shadow_color = Color{40, 45, 70, 70},
	button_primary_grad_top = Color{255, 255, 255, 55},
	button_primary_grad_bottom = Color{0, 0, 0, 0},
	paper_rule = Color{0, 0, 0, 0},
	paper_tooth = Color{0, 0, 0, 0},
	graphite = Color{0, 0, 0, 0},
	highlighter = Color{0, 0, 0, 0},
	tape_color = Color{0, 0, 0, 0},
	ink_faded = Color{130, 130, 140, 255},
	fg_on_accent = Color{255, 255, 255, 255},
	caption_hover = Color{222, 222, 228, 255},
	caption_pressed = Color{204, 204, 212, 255},
	caption_close_hover = Color{232, 64, 52, 255},
	caption_close_pressed = Color{180, 40, 32, 255},
	spell_error = Color{190, 40, 40, 255},
	substrate = Substrate{kind = .None, margin_rule = false},
}

// THEME_HIGH_CONTRAST is a maximum-legibility palette: opaque black
// surfaces, white text, yellow accents (the highest-luminance hue), no
// translucency or glass. Every text/background role pair clears WCAG AA by a
// wide margin; the focus ring is fully opaque.
THEME_HIGH_CONTRAST :: Theme {
	bg_app = Color{0, 0, 0, 255},
	bg_chat = Color{0, 0, 0, 255},
	bg_panel = Color{0, 0, 0, 255},
	bg_app_windowed = Color{0, 0, 0, 255},
	bg_chat_windowed = Color{0, 0, 0, 255},
	bg_panel_windowed = Color{0, 0, 0, 255},
	bg_app_fullscreen = Color{0, 0, 0, 255},
	bg_chat_fullscreen = Color{0, 0, 0, 255},
	bg_panel_fullscreen = Color{0, 0, 0, 255},
	bg_color = Color{0, 0, 0, 255},
	bg_secondary = Color{15, 15, 15, 255},
	bg_active = Color{60, 60, 60, 255},
	bg_hover = Color{40, 40, 40, 255},
	bg_input = Color{0, 0, 0, 255},
	bg_code = Color{15, 15, 15, 255},
	fg_primary = Color{255, 255, 255, 255},
	fg_secondary = Color{255, 255, 255, 255},
	fg_accent = Color{255, 215, 0, 255},
	fg_user = Color{255, 255, 255, 255},
	fg_assistant = Color{255, 255, 255, 255},
	fg_error = Color{255, 100, 100, 255},
	fg_success = Color{100, 255, 100, 255},
	fg_tool = Color{255, 215, 0, 255},
	fg_diff_remove = Color{255, 130, 130, 255},
	fg_diff_add = Color{130, 255, 130, 255},
	bg_diff_remove = Color{60, 0, 0, 255},
	bg_diff_add = Color{0, 50, 0, 255},
	fg_diff_gutter = Color{255, 255, 255, 255},
	border_color = Color{255, 255, 255, 255},
	border_subtle = Color{200, 200, 200, 255},
	badge_color = Color{255, 100, 100, 255},
	merge_link_color = Color{255, 215, 0, 255},
	button_bg = Color{255, 215, 0, 255},
	button_hover = Color{255, 255, 255, 255},
	button_text = Color{0, 0, 0, 255},
	bg_popup = Color{0, 0, 0, 255},
	fg_disabled = Color{160, 160, 160, 255},
	bg_plan_bar = Color{45, 45, 0, 255},
	fg_plan = Color{255, 215, 0, 255},
	fg_planning = Color{255, 215, 0, 255},
	bg_selection = Color{90, 90, 0, 255},
	bg_plan_title = Color{30, 30, 0, 255},
	bg_tool_card = Color{15, 15, 15, 255},
	bg_tool_card_hover = Color{40, 40, 40, 255},
	fg_heading = Color{255, 255, 255, 255},
	fg_bullet = Color{255, 215, 0, 255},
	fg_bold = Color{255, 255, 255, 255},
	fg_code_inline = Color{255, 215, 0, 255},
	bg_table_header = Color{30, 30, 30, 255},
	wave_color_a = Color{255, 215, 0, 255},
	wave_color_b = Color{255, 255, 255, 255},
	drop_zone_bg = Color{45, 45, 0, 255},
	drop_zone_border = Color{255, 215, 0, 255},
	fg_debug = Color{255, 215, 0, 255},
	bg_debug_title = Color{30, 30, 30, 255},
	fg_debug_changed = Color{255, 215, 0, 255},
	fg_debug_annotation = Color{255, 255, 255, 255},
	bg_chip = Color{30, 30, 30, 255},
	bg_chip_hover = Color{55, 55, 55, 255},
	bg_user_card = Color{20, 20, 20, 255},
	border_user_card = Color{255, 255, 255, 255},
	bg_band_error = Color{60, 0, 0, 255},
	fg_label = Color{255, 255, 255, 255},
	button_danger_bg = Color{90, 0, 0, 255},
	button_danger_hover = Color{130, 0, 0, 255},
	button_danger_fg = Color{255, 130, 130, 255},
	button_disabled_bg = Color{30, 30, 30, 255},
	// Pressed was pure white, identical to button_hover, so a high-contrast
	// button gave no feedback distinguishable from hover. Amber sits between
	// the gold rest state and the white hover state in luminance, keeps black
	// button_text far above AA, and stays inside the palette's yellow accent
	// language rather than introducing a hue only this state uses.
	button_pressed = Color{255, 170, 0, 255},
	surface_pressed = Color{90, 90, 90, 255},
	fg_accent_light = Color{255, 215, 0, 255},
	fg_muted_dim = Color{190, 190, 190, 255},
	modal_dim = Color{0, 0, 0, 210},
	focus_ring = Color{255, 215, 0, 255},
	shadow_color = Color{0, 0, 0, 0},
	button_primary_grad_top = Color{0, 0, 0, 0},
	button_primary_grad_bottom = Color{0, 0, 0, 0},
	paper_rule = Color{0, 0, 0, 0},
	paper_tooth = Color{0, 0, 0, 0},
	graphite = Color{0, 0, 0, 0},
	highlighter = Color{0, 0, 0, 0},
	tape_color = Color{0, 0, 0, 0},
	ink_faded = Color{200, 200, 200, 255},
	fg_on_accent = Color{0, 0, 0, 255},
	// The caption buttons this palette shipped were a 10-to-15 alpha white
	// wash over pure black: a different color by inspection, and no visible
	// feedback at all in use. These are opaque for that reason.
	caption_hover = Color{255, 255, 255, 255},
	caption_pressed = Color{255, 215, 0, 255},
	caption_close_hover = Color{255, 80, 80, 255},
	caption_close_pressed = Color{255, 140, 140, 255},
	spell_error = Color{255, 100, 100, 255},
	substrate = Substrate{kind = .None, margin_rule = false},
}

// THEME_COLOR is the zero-color sentinel for widget color parameters whose
// real default is a theme field. Odin default parameter values must be
// compile-time constants while the theme is runtime data, so widgets compare
// against this named sentinel and substitute the theme color at call time.
THEME_COLOR :: Color{0, 0, 0, 0}

// theme_dark returns the built-in dark palette (the original constants).
theme_dark :: proc() -> Theme {
	return THEME_DARK
}

// theme_light returns the built-in light palette.
theme_light :: proc() -> Theme {
	return THEME_LIGHT
}

// theme_high_contrast returns the built-in high-contrast palette.
theme_high_contrast :: proc() -> Theme {
	return THEME_HIGH_CONTRAST
}

// relative_luminance returns the WCAG relative luminance of a color
// (0 = black, 1 = white). Pure; alpha is ignored.
relative_luminance :: proc(c: Color) -> f64 {
	linearize :: proc(channel: u8) -> f64 {
		v := f64(channel) / 255.0
		if v <= 0.04045 do return v / 12.92
		return math.pow((v + 0.055) / 1.055, 2.4)
	}
	return 0.2126 * linearize(c.r) + 0.7152 * linearize(c.g) + 0.0722 * linearize(c.b)
}

// contrast_ratio returns the WCAG contrast ratio between two colors, in
// [1, 21]. Pure; order of arguments does not matter.
contrast_ratio :: proc(a, b: Color) -> f64 {
	la := relative_luminance(a)
	lb := relative_luminance(b)
	hi := max(la, lb)
	lo := min(la, lb)
	ratio := (hi + 0.05) / (lo + 0.05)
	assert(ratio >= 1 && ratio <= 21, "contrast_ratio: out of WCAG range")
	return ratio
}

// MIN_TEXT_CONTRAST is WCAG 2.1 AA for normal text.
MIN_TEXT_CONTRAST :: 4.5

ui_runtime_set_theme :: proc(runtime: ^Ui_Runtime, value: Theme) {
	assert(runtime != nil && runtime.initialized, "set_theme: invalid runtime")
	assert(value.fg_primary.a != 0, "set_theme: fg_primary must be opaque-ish")
	assert(value.bg_color.a != 0, "set_theme: bg_color must have alpha")
	assert(
		contrast_ratio(value.fg_primary, value.bg_color) >= MIN_TEXT_CONTRAST,
		"set_theme: fg_primary on bg_color below WCAG AA (4.5:1)",
	)
	assert(
		contrast_ratio(value.button_text, value.button_bg) >= MIN_TEXT_CONTRAST,
		"set_theme: button_text on button_bg below WCAG AA (4.5:1)",
	)
	runtime.style = value
	runtime.style.bg_app = value.bg_app_windowed
	runtime.style.bg_chat = value.bg_chat_windowed
	runtime.style.bg_panel = value.bg_panel_windowed
	if runtime.scale_invalidate_hook != nil do runtime.scale_invalidate_hook()
	runtime.generation += 1
}

ui_runtime_set_glass_fullscreen :: proc(runtime: ^Ui_Runtime, fullscreen: bool) {
	assert(runtime != nil && runtime.initialized, "glass: invalid runtime")
	theme := &runtime.style
	assert(theme.bg_app_windowed.a != 0, "glass: bg_app_windowed unset")
	assert(theme.bg_app_fullscreen.a != 0, "glass: bg_app_fullscreen unset")
	if fullscreen {
		theme.bg_app = theme.bg_app_fullscreen
		theme.bg_chat = theme.bg_chat_fullscreen
		theme.bg_panel = theme.bg_panel_fullscreen
	} else {
		theme.bg_app = theme.bg_app_windowed
		theme.bg_chat = theme.bg_chat_windowed
		theme.bg_panel = theme.bg_panel_windowed
	}
}

// Unified button system (shape metrics, not colors).
//
// Superseded by the Radius and Border tokens in tokens.odin. These remain
// exported and unchanged for one release because consumers outside this
// repository draw button-shaped surfaces with them.
//
// BTN_ROUNDNESS is the specific value the tokens exist to retire: it is a
// *ratio*, so the same 0.3 yields a visibly different corner on a 24px button
// than on a 200px card, and no amount of care at a call site can make the two
// agree. radius_ratio takes an absolute radius and converts it per-rect, which
// is what lets a button and the card beside it match at every UI scale.
// Prefer radius_ratio, radius_segments, and border_pixels in new code.
BTN_ROUNDNESS :: f32(0.3)
BTN_SEGMENTS :: i32(6)
BTN_BORDER_W :: f32(1.0)

// Agent-busy wave bar.
WAVE_BAR_COUNT :: 28 // number of bars (count, not pixels)

// Circular wave-ring connecting animation.
VORTEX_SQUASH :: f32(0.82) // vertical squash ratio (not a pixel size)

// Split view ratios (not pixel sizes).
SPLIT_MIN_RATIO :: f32(0.2)
SPLIT_MAX_RATIO :: f32(0.8)

// User prompt card width ratio within the chat column (not a pixel size).
USER_CARD_MAX_RATIO :: f32(0.72)

// Drag-and-drop delivery animation duration (seconds, not pixels).
DROP_ANIM_DUR :: 0.85

// Nvim scroll speed (separate from UI scroll; nvim handles its own DPI).
NVIM_SCROLL_SPEED :: 0.5

// Input and cache limits (character / entry counts, not pixels).
INPUT_MAX_LEN :: 262144
TOOL_MAX_LINES :: 20

// Hover dwell before a tooltip appears (seconds; not a pixel size).
TOOLTIP_DELAY :: 0.55

// Alpha applied to a pill's tint fill (count 0-255, not a pixel size).
PILL_TINT_ALPHA :: u8(38)

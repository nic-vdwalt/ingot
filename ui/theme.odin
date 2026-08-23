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
// Pigment names a paint colour: laid as an area, carrying no text.
//
// This is a separate table from the fg_* inks, and the separation is the whole
// reason the sketch palettes can be properly toned.
//
// The pigments were originally the *same values* as the matching inks. That
// made every pigment inherit a text role's duty to clear WCAG AA against the
// ground - and since a swatch must pass, the lightest pigment then dictated
// how light the paper could be. Yellow ochre, the lightest of the set, held
// the ground two full steps paler than real toned stock. The reasoning was
// circular and it was written into the palette as though it were a law of
// colour rather than a consequence of one modelling choice.
//
// Paint carries no text, so it is bound by no text-contrast rule and can be
// saturated. Ink carries text and must be deep enough to read. Two tables
// because they are two jobs; sharing one value means whichever constraint is
// stricter silently governs both.
Pigment :: enum u8 {
	Accent,
	Danger,
	Success,
	Tool,
	Earth,
	Leaf,
}

// pigment_ink pairs each pigment with the ink that names the same idea.
//
// Exposed so the pairing is iterable: the invariant "a pigment is at least as
// saturated as its ink" is then a loop over the enum rather than six
// hand-written assertions that a seventh pigment would silently escape.
pigment_ink :: proc(pigment: Pigment) -> Ink {
	switch pigment {
	case .Accent:
		return .Accent
	case .Danger:
		return .Danger
	case .Success:
		return .Success
	case .Tool:
		return .Tool
	case .Earth:
		return .Diff_Remove
	case .Leaf:
		return .Assistant
	}
	return .Primary
}

// theme_pigment resolves a pigment against a palette, falling back to the
// matching ink when the palette carries no paint.
//
// The fallback is what lets a pigment-aware widget draw on a screen palette
// without a branch at every call site: THEME_DARK has no pigments, so a
// pigment block there is simply drawn in the corresponding ink.
theme_pigment :: proc(style: ^Theme, pigment: Pigment) -> Color {
	assert(style != nil, "theme_pigment: nil theme")
	// The switch is not decoration: the lookup is total over the enum, so a
	// range assertion would be the tautology TIGER_STYLE.md forbids by name,
	// and switching keeps the totality visible to the compiler instead - a
	// pigment added without a case here is a build error rather than a silent
	// zero. The assertion gate reaches the same conclusion from the other
	// direction: it wants len()/cap() evidence, which an enum-indexed table
	// has no way to supply.
	color: Color
	switch pigment {
	case .Accent:
		color = style.pigments[Pigment.Accent]
	case .Danger:
		color = style.pigments[Pigment.Danger]
	case .Success:
		color = style.pigments[Pigment.Success]
	case .Tool:
		color = style.pigments[Pigment.Tool]
	case .Earth:
		color = style.pigments[Pigment.Earth]
	case .Leaf:
		color = style.pigments[Pigment.Leaf]
	}
	// A palette may leave a pigment unset; the caller must never receive a
	// transparent colour. That is the contract worth asserting.
	if color.a == 0 do color = theme_ink(style, pigment_ink(pigment))
	assert(color.a > 0, "theme_pigment: resolved a fully transparent pigment")
	return color
}

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
	chalk = Color{0, 0, 0, 0},
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
	chalk = Color{0, 0, 0, 0},
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
	chalk = Color{0, 0, 0, 0},
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

theme_retro_orange :: proc() -> Theme {
	result := THEME_LIGHT
	paper := Color{250, 246, 236, 255}
	panel := Color{255, 250, 239, 255}
	card := Color{255, 253, 246, 255}
	pale := Color{249, 213, 166, 255}
	hover := Color{244, 184, 112, 255}
	pressed := Color{232, 149, 62, 255}
	orange := Color{159, 72, 19, 255}
	ink := Color{53, 35, 24, 255}
	muted := Color{102, 75, 55, 255}
	result.bg_app = paper
	result.bg_chat = paper
	result.bg_panel = panel
	result.bg_app_windowed = paper
	result.bg_chat_windowed = paper
	result.bg_panel_windowed = panel
	result.bg_app_fullscreen = paper
	result.bg_chat_fullscreen = paper
	result.bg_panel_fullscreen = panel
	result.bg_color = paper
	result.bg_secondary = panel
	result.bg_active = pale
	result.bg_hover = hover
	result.bg_input = card
	result.bg_code = Color{246, 235, 215, 255}
	result.fg_primary = ink
	result.fg_secondary = muted
	result.fg_accent = orange
	result.fg_user = Color{126, 57, 21, 255}
	result.fg_assistant = Color{67, 91, 51, 255}
	result.fg_tool = Color{127, 78, 15, 255}
	result.border_color = orange
	result.border_subtle = Color{198, 128, 71, 255}
	result.button_bg = pale
	result.button_hover = hover
	result.button_text = ink
	result.bg_popup = card
	result.bg_selection = Color{247, 196, 132, 255}
	result.bg_plan_bar = Color{247, 220, 180, 255}
	result.fg_plan = orange
	result.fg_planning = orange
	result.bg_plan_title = Color{250, 228, 195, 255}
	result.bg_tool_card = card
	result.bg_tool_card_hover = Color{250, 224, 188, 255}
	result.fg_heading = ink
	result.fg_bullet = orange
	result.fg_bold = Color{37, 24, 17, 255}
	result.fg_code_inline = Color{133, 60, 17, 255}
	result.bg_table_header = Color{249, 218, 177, 255}
	result.wave_color_a = orange
	result.wave_color_b = pressed
	result.drop_zone_bg = Color{250, 221, 181, 235}
	result.drop_zone_border = orange
	result.bg_chip = Color{248, 222, 187, 255}
	result.bg_chip_hover = hover
	result.bg_user_card = Color{252, 232, 204, 255}
	result.border_user_card = Color{196, 112, 53, 255}
	result.bg_band_error = Color{252, 225, 210, 255}
	result.fg_label = Color{116, 72, 42, 255}
	result.button_danger_bg = Color{247, 211, 190, 255}
	result.button_danger_hover = Color{239, 178, 145, 255}
	result.button_danger_fg = Color{130, 38, 20, 255}
	result.button_disabled_bg = Color{235, 226, 211, 255}
	result.button_pressed = pressed
	result.surface_pressed = Color{235, 170, 97, 255}
	result.fg_accent_light = orange
	result.fg_muted_dim = Color{143, 119, 99, 255}
	result.focus_ring = Color{159, 72, 19, 220}
	result.shadow_color = Color{91, 51, 24, 55}
	result.button_primary_grad_top = Color{255, 255, 255, 70}
	result.ink_faded = Color{142, 104, 75, 255}
	result.fg_on_accent = ink
	result.caption_hover = Color{247, 207, 157, 255}
	result.caption_pressed = pressed
	return result
}

theme_retro_orange_dark :: proc() -> Theme {
	result := THEME_DARK
	ground := Color{28, 20, 15, 255}
	panel := Color{38, 27, 19, 255}
	card := Color{45, 31, 21, 255}
	pale := Color{69, 40, 25, 255}
	hover := Color{84, 46, 24, 255}
	pressed := Color{111, 57, 22, 255}
	orange := Color{255, 170, 92, 255}
	ink := Color{244, 226, 203, 255}
	muted := Color{205, 174, 143, 255}
	result.bg_app = ground
	result.bg_chat = ground
	result.bg_panel = panel
	result.bg_app_windowed = ground
	result.bg_chat_windowed = ground
	result.bg_panel_windowed = panel
	result.bg_app_fullscreen = ground
	result.bg_chat_fullscreen = ground
	result.bg_panel_fullscreen = panel
	result.bg_color = ground
	result.bg_secondary = panel
	result.bg_active = pale
	result.bg_hover = hover
	result.bg_input = card
	result.bg_code = Color{35, 25, 18, 255}
	result.fg_primary = ink
	result.fg_secondary = muted
	result.fg_accent = orange
	result.fg_user = Color{255, 190, 125, 255}
	result.fg_assistant = Color{177, 211, 144, 255}
	result.fg_tool = Color{238, 187, 104, 255}
	result.border_color = Color{184, 101, 48, 255}
	result.border_subtle = Color{91, 57, 37, 255}
	result.button_bg = Color{108, 52, 20, 255}
	result.button_hover = Color{133, 65, 22, 255}
	result.button_text = ink
	result.bg_popup = card
	result.bg_selection = Color{91, 52, 26, 255}
	result.bg_plan_bar = Color{57, 41, 20, 255}
	result.fg_plan = orange
	result.fg_planning = orange
	result.bg_plan_title = Color{49, 34, 19, 255}
	result.bg_tool_card = card
	result.bg_tool_card_hover = Color{59, 38, 22, 255}
	result.fg_heading = Color{255, 239, 218, 255}
	result.fg_bullet = orange
	result.fg_bold = Color{255, 245, 231, 255}
	result.fg_code_inline = Color{255, 188, 116, 255}
	result.bg_table_header = Color{56, 38, 24, 255}
	result.wave_color_a = Color{159, 72, 19, 255}
	result.wave_color_b = orange
	result.drop_zone_bg = Color{72, 43, 24, 235}
	result.drop_zone_border = orange
	result.bg_chip = Color{58, 38, 23, 255}
	result.bg_chip_hover = hover
	result.bg_user_card = Color{55, 35, 21, 255}
	result.border_user_card = Color{145, 78, 39, 255}
	result.bg_band_error = Color{63, 29, 23, 255}
	result.fg_label = Color{190, 143, 106, 255}
	result.button_danger_bg = Color{75, 31, 24, 255}
	result.button_danger_hover = Color{103, 39, 28, 255}
	result.button_danger_fg = Color{255, 174, 146, 255}
	result.button_disabled_bg = Color{48, 39, 32, 255}
	result.button_pressed = Color{156, 78, 25, 255}
	result.surface_pressed = pressed
	result.fg_accent_light = Color{255, 196, 132, 255}
	result.fg_muted_dim = Color{151, 119, 92, 255}
	result.focus_ring = Color{255, 170, 92, 230}
	result.shadow_color = Color{0, 0, 0, 145}
	result.button_primary_grad_top = Color{255, 225, 186, 35}
	result.ink_faded = Color{166, 128, 96, 255}
	result.fg_on_accent = Color{35, 23, 16, 255}
	result.caption_hover = Color{75, 44, 25, 255}
	result.caption_pressed = pressed
	return result
}

theme_retro_ingot :: proc() -> Theme {
	result := THEME_LIGHT
	paper := Color{245, 245, 247, 255}
	panel := Color{232, 237, 240, 255}
	card := Color{255, 255, 255, 255}
	pale := Color{213, 218, 222, 255}
	hover := Color{185, 192, 197, 255}
	pressed := Color{139, 146, 154, 255}
	steel := Color{115, 122, 130, 255}
	ink := Color{17, 19, 24, 255}
	muted := Color{30, 30, 30, 255}
	result.bg_app = paper
	result.bg_chat = paper
	result.bg_panel = panel
	result.bg_app_windowed = paper
	result.bg_chat_windowed = paper
	result.bg_panel_windowed = panel
	result.bg_app_fullscreen = paper
	result.bg_chat_fullscreen = paper
	result.bg_panel_fullscreen = panel
	result.bg_color = paper
	result.bg_secondary = panel
	result.bg_active = pale
	result.bg_hover = hover
	result.bg_input = card
	result.bg_code = Color{232, 237, 240, 255}
	result.fg_primary = ink
	result.fg_secondary = muted
	result.fg_accent = steel
	result.fg_user = Color{30, 30, 30, 255}
	result.fg_assistant = Color{115, 122, 130, 255}
	result.fg_tool = Color{30, 30, 30, 255}
	result.border_color = steel
	result.border_subtle = Color{174, 182, 189, 255}
	result.button_bg = pale
	result.button_hover = hover
	result.button_text = ink
	result.bg_popup = card
	result.bg_selection = Color{185, 192, 197, 255}
	result.bg_plan_bar = Color{213, 218, 222, 255}
	result.fg_plan = steel
	result.fg_planning = steel
	result.bg_plan_title = Color{232, 237, 240, 255}
	result.bg_tool_card = card
	result.bg_tool_card_hover = Color{232, 237, 240, 255}
	result.fg_heading = ink
	result.fg_bullet = steel
	result.fg_bold = ink
	result.fg_code_inline = Color{30, 30, 30, 255}
	result.bg_table_header = Color{213, 218, 222, 255}
	result.wave_color_a = steel
	result.wave_color_b = pressed
	result.drop_zone_bg = Color{213, 218, 222, 235}
	result.drop_zone_border = steel
	result.bg_chip = Color{213, 218, 222, 255}
	result.bg_chip_hover = hover
	result.bg_user_card = Color{232, 237, 240, 255}
	result.border_user_card = steel
	result.bg_band_error = Color{232, 237, 240, 255}
	result.fg_label = Color{30, 30, 30, 255}
	result.button_danger_bg = Color{213, 218, 222, 255}
	result.button_danger_hover = Color{185, 192, 197, 255}
	result.button_danger_fg = ink
	result.button_disabled_bg = Color{232, 237, 240, 255}
	result.button_pressed = pressed
	result.surface_pressed = Color{174, 182, 189, 255}
	result.fg_accent_light = steel
	result.fg_muted_dim = Color{115, 122, 130, 255}
	result.focus_ring = Color{115, 122, 130, 220}
	result.shadow_color = Color{17, 19, 24, 55}
	result.button_primary_grad_top = Color{255, 255, 255, 70}
	result.ink_faded = Color{115, 122, 130, 255}
	result.fg_on_accent = ink
	result.caption_hover = Color{213, 218, 222, 255}
	result.caption_pressed = pressed
	return result
}

theme_retro_ingot_dark :: proc() -> Theme {
	result := THEME_DARK
	ground := Color{18, 20, 24, 255}
	panel := Color{27, 31, 36, 255}
	card := Color{34, 39, 45, 255}
	pale := Color{55, 62, 69, 255}
	hover := Color{68, 76, 84, 255}
	pressed := Color{88, 97, 106, 255}
	steel := Color{178, 190, 202, 255}
	ink := Color{238, 241, 244, 255}
	muted := Color{183, 190, 198, 255}
	result.bg_app = ground
	result.bg_chat = ground
	result.bg_panel = panel
	result.bg_app_windowed = ground
	result.bg_chat_windowed = ground
	result.bg_panel_windowed = panel
	result.bg_app_fullscreen = ground
	result.bg_chat_fullscreen = ground
	result.bg_panel_fullscreen = panel
	result.bg_color = ground
	result.bg_secondary = panel
	result.bg_active = pale
	result.bg_hover = hover
	result.bg_input = card
	result.bg_code = Color{24, 28, 33, 255}
	result.fg_primary = ink
	result.fg_secondary = muted
	result.fg_accent = steel
	result.fg_user = Color{224, 230, 236, 255}
	result.fg_assistant = Color{188, 201, 190, 255}
	result.fg_tool = Color{211, 196, 158, 255}
	result.border_color = Color{119, 132, 144, 255}
	result.border_subtle = Color{57, 65, 73, 255}
	result.button_bg = Color{68, 76, 85, 255}
	result.button_hover = Color{82, 91, 101, 255}
	result.button_text = ink
	result.bg_popup = card
	result.bg_selection = Color{62, 71, 81, 255}
	result.bg_plan_bar = Color{46, 46, 39, 255}
	result.fg_plan = Color{224, 198, 132, 255}
	result.fg_planning = steel
	result.bg_plan_title = Color{39, 40, 36, 255}
	result.bg_tool_card = card
	result.bg_tool_card_hover = Color{46, 52, 59, 255}
	result.fg_heading = Color{250, 252, 255, 255}
	result.fg_bullet = steel
	result.fg_bold = Color{255, 255, 255, 255}
	result.fg_code_inline = Color{211, 196, 158, 255}
	result.bg_table_header = Color{45, 51, 58, 255}
	result.wave_color_a = Color{103, 116, 129, 255}
	result.wave_color_b = steel
	result.drop_zone_bg = Color{51, 59, 68, 235}
	result.drop_zone_border = steel
	result.bg_chip = Color{48, 55, 63, 255}
	result.bg_chip_hover = hover
	result.bg_user_card = Color{42, 48, 55, 255}
	result.border_user_card = Color{103, 116, 129, 255}
	result.bg_band_error = Color{57, 35, 36, 255}
	result.fg_label = Color{158, 168, 178, 255}
	result.button_danger_bg = Color{67, 40, 41, 255}
	result.button_danger_hover = Color{91, 46, 47, 255}
	result.button_danger_fg = Color{255, 181, 181, 255}
	result.button_disabled_bg = Color{43, 47, 52, 255}
	result.button_pressed = Color{101, 112, 123, 255}
	result.surface_pressed = pressed
	result.fg_accent_light = Color{207, 218, 229, 255}
	result.fg_muted_dim = Color{128, 139, 150, 255}
	result.focus_ring = Color{178, 190, 202, 230}
	result.shadow_color = Color{0, 0, 0, 150}
	result.button_primary_grad_top = Color{255, 255, 255, 28}
	result.ink_faded = Color{143, 154, 165, 255}
	result.fg_on_accent = Color{17, 19, 24, 255}
	result.caption_hover = Color{58, 65, 73, 255}
	result.caption_pressed = pressed
	return result
}

theme_terra :: proc() -> Theme {
	result := THEME_DARK
	phosphor := Color{176, 255, 206, 255}
	phosphor_bright := Color{120, 255, 170, 255}
	phosphor_dim := Color{112, 190, 146, 255}
	phosphor_faint := Color{88, 150, 116, 255}
	amber := Color{255, 190, 90, 255}
	danger := Color{255, 106, 84, 255}
	glass := Color{6, 10, 8, 255}
	panel := Color{9, 15, 12, 236}
	result.bg_app_windowed = glass
	result.bg_chat_windowed = panel
	result.bg_panel_windowed = panel
	result.bg_app_fullscreen = glass
	result.bg_chat_fullscreen = Color{9, 15, 12, 252}
	result.bg_panel_fullscreen = Color{9, 15, 12, 252}
	result.bg_app = result.bg_app_windowed
	result.bg_chat = result.bg_chat_windowed
	result.bg_panel = result.bg_panel_windowed
	result.bg_color = glass
	result.bg_secondary = Color{13, 22, 18, 255}
	result.bg_active = Color{18, 44, 32, 255}
	result.bg_hover = Color{16, 34, 26, 255}
	result.bg_input = Color{5, 9, 8, 255}
	result.bg_code = Color{8, 14, 11, 255}
	result.bg_popup = Color{7, 12, 10, 244}
	result.bg_selection = Color{22, 62, 42, 255}
	result.bg_table_header = Color{12, 24, 18, 255}
	result.bg_tool_card = Color{11, 19, 15, 255}
	result.bg_tool_card_hover = Color{16, 30, 23, 255}
	result.bg_chip = Color{14, 28, 21, 255}
	result.bg_chip_hover = Color{20, 40, 30, 255}
	result.bg_user_card = Color{12, 24, 18, 255}
	result.bg_band_error = Color{42, 16, 12, 255}
	result.bg_plan_bar = Color{34, 26, 8, 255}
	result.bg_plan_title = Color{28, 22, 8, 255}
	result.bg_debug_title = Color{12, 24, 18, 255}
	result.bg_diff_add = Color{10, 32, 20, 255}
	result.bg_diff_remove = Color{42, 16, 12, 255}
	result.fg_primary = phosphor
	result.fg_heading = Color{214, 255, 228, 255}
	result.fg_secondary = phosphor_dim
	result.fg_accent = phosphor_bright
	result.fg_accent_light = Color{164, 255, 200, 255}
	result.fg_label = phosphor_faint
	result.fg_muted_dim = phosphor_faint
	result.fg_disabled = Color{52, 88, 70, 255}
	result.fg_user = phosphor
	result.fg_assistant = phosphor_dim
	result.fg_bold = Color{214, 255, 228, 255}
	result.fg_bullet = phosphor_bright
	result.fg_code_inline = amber
	result.fg_tool = amber
	result.fg_plan = amber
	result.fg_planning = amber
	result.fg_debug_changed = amber
	result.fg_debug = Color{164, 255, 200, 255}
	result.fg_debug_annotation = phosphor_dim
	result.fg_error = danger
	result.fg_success = phosphor_bright
	result.fg_diff_add = phosphor_bright
	result.fg_diff_remove = danger
	result.fg_diff_gutter = phosphor_faint
	result.ink_faded = phosphor_faint
	result.spell_error = danger
	result.border_color = Color{46, 120, 86, 255}
	result.border_subtle = Color{26, 66, 48, 255}
	result.border_user_card = Color{26, 66, 48, 255}
	result.badge_color = amber
	result.merge_link_color = Color{46, 120, 86, 255}
	result.button_bg = Color{36, 150, 96, 255}
	result.button_hover = Color{52, 186, 122, 255}
	result.button_text = Color{4, 12, 8, 255}
	result.button_pressed = Color{96, 230, 152, 255}
	result.button_disabled_bg = Color{12, 22, 17, 255}
	result.button_danger_bg = Color{58, 20, 15, 255}
	result.button_danger_hover = Color{82, 28, 20, 255}
	result.button_danger_fg = Color{255, 158, 140, 255}
	result.surface_pressed = Color{30, 74, 54, 255}
	result.fg_on_accent = Color{4, 12, 8, 255}
	result.focus_ring = Color{120, 255, 170, 230}
	result.modal_dim = Color{2, 6, 4, 220}
	result.shadow_color = Color{0, 0, 0, 150}
	result.button_primary_grad_top = Color{176, 255, 206, 26}
	result.button_primary_grad_bottom = Color{0, 0, 0, 0}
	result.caption_hover = Color{18, 44, 32, 255}
	result.caption_pressed = Color{30, 74, 54, 255}
	result.caption_close_hover = Color{168, 46, 34, 255}
	result.caption_close_pressed = Color{210, 62, 46, 255}
	result.drop_zone_bg = Color{12, 30, 22, 235}
	result.drop_zone_border = phosphor_bright
	result.wave_color_a = Color{26, 78, 54, 255}
	result.wave_color_b = phosphor_bright
	result.substrate = {
		kind        = .Grid,
		margin_rule = false,
	}
	return result
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
MIN_TEXT_CONTRAST_LARGE :: 3.0

READING_INKS :: [?]Ink {
	.Primary,
	.Heading,
	.Secondary,
	.Accent,
	.Danger,
	.Success,
	.Label,
	.Accent_Light,
	.Tool,
	.Diff_Add,
	.Diff_Remove,
	.User,
	.Assistant,
	.Plan,
}

theme_reading_surfaces :: proc(style: ^Theme) -> [6]Color {
	assert(style != nil, "theme_reading_surfaces: nil theme")
	return [6]Color {
		style.bg_color,
		style.bg_secondary,
		style.bg_input,
		style.bg_code,
		style.bg_popup,
		style.bg_tool_card,
	}
}

theme_reading_matrix_min_ratio :: proc(style: ^Theme) -> f64 {
	assert(style != nil, "theme_reading_matrix_min_ratio: nil theme")
	minimum := f64(21)
	for ink in READING_INKS {
		color := theme_ink(style, ink)
		for surface in theme_reading_surfaces(style) {
			minimum = min(minimum, contrast_ratio(color, surface))
		}
	}
	assert(minimum >= 1 && minimum <= 21, "theme_reading_matrix_min_ratio: invalid ratio")
	return minimum
}

ui_runtime_apply_theme :: proc(runtime: ^Ui_Runtime, value: Theme) {
	assert(runtime != nil, "apply_theme: nil runtime")
	assert(runtime.initialized, "apply_theme: runtime not initialized")
	runtime.style = value
	runtime.style.bg_app = value.bg_app_windowed
	runtime.style.bg_chat = value.bg_chat_windowed
	runtime.style.bg_panel = value.bg_panel_windowed
	if runtime.scale_invalidate_hook != nil do runtime.scale_invalidate_hook()
	runtime.generation += 1
}

ui_runtime_try_set_theme :: proc(runtime: ^Ui_Runtime, value: Theme) -> Theme_Validation {
	assert(runtime != nil, "try_set_theme: nil runtime")
	assert(runtime.initialized, "try_set_theme: runtime not initialized")
	validation := Theme_Validate(value)
	if validation.code != .Valid do return validation
	ui_runtime_apply_theme(runtime, value)
	return validation
}

ui_runtime_set_theme :: proc(runtime: ^Ui_Runtime, value: Theme) {
	assert(runtime != nil, "set_theme: nil runtime")
	assert(runtime.initialized, "set_theme: runtime not initialized")
	validation := Theme_Validate(value)
	assert(validation.code == .Valid, "set_theme: invalid theme")
	ui_runtime_apply_theme(runtime, value)
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

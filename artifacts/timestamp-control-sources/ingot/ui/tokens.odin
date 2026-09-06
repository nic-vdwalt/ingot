// LIB-CANDIDATE: this package must import only core:*.
//
// Surface tokens: the missing peer of Text_Role/Ink (text_api.odin) and Space
// (layout.odin). Those three name what a *string* and a *gap* mean; nothing
// named what a filled region means, so every widget hardcoded its own answer.
//
// The cost of that gap was measurable before this file existed:
//
//   - Seven mutually unreconcilable corner radii. BTN_ROUNDNESS is a ratio
//     (theme.odin) while CARD_RADIUS_PX is absolute pixels (scale.odin), so a
//     button and a card of equal height could not be made to match at any
//     scale, and five more raw literals had accumulated around them.
//   - Border widths scaled in some call sites and not others, so at 2x UI scale
//     a dropdown field's border was one screen-space pixel while its own popup's
//     was two.
//   - "Disabled" resolved to fg_muted_dim in buttons and fg_disabled in menus.
//   - "Pressed" existed only for buttons; rows, tabs and menu items had no
//     press feedback at all.
//
// Resolving a token is therefore the *only* sanctioned way to answer those
// questions. Everything here is pure: tokens in, colors and pixels out, no
// frame state mutated.
package ui

// Radius names the corner treatment a surface class uses. Every value resolves
// through Ui_Metrics.CARD_RADIUS_PX so all corners scale together.
//
// The unit is deliberately pixels-then-converted rather than a ratio. A ratio
// is unusable as a shared token because the same 0.3 produces a different
// visual corner on a 24px button than on a 200px card; only an absolute radius
// converted per-rect makes two adjacent surfaces agree.
Radius :: enum u8 {
	None,
	SM,
	MD,
	LG,
	Pill,
}

// Border names hairline weights. Each is DPI-scaled exactly once, here, which
// is what makes an unscaled numeric width at a draw call unambiguously a bug
// rather than a judgement call.
Border :: enum u8 {
	None,
	Hairline,
	Emphasis,
	Ink,
}

// Elevation names how far a surface floats above its parent. It resolves to a
// hard offset rather than a blur radius: the engine has no blur primitive, and
// the stacked-ring approximation it replaces cost four draw commands per card
// to imitate one.
Elevation :: enum u8 {
	Flat,
	Lifted,
	Overlay,
	Modal,
}

// Visual_State is the interaction state a surface is painted in. Ordered by
// increasing emphasis so tests can assert that a palette moves contrast
// monotonically rather than merely making the states differ.
Visual_State :: enum u8 {
	Rest,
	Hover,
	Pressed,
	Selected,
	Disabled,
}

// Surface names the semantic class of a filled region.
Surface :: enum u8 {
	App,
	Panel,
	Card,
	Popup,
	Input,
	Row,
	Chip,
	Code,
	Table_Header,
	Button_Primary,
	Button_Secondary,
	Button_Danger,
	Button_Ghost,
}

// Tint names the translucency levels overlays use, replacing five undocumented
// alpha literals that had drifted apart across widgets, charts and the debug
// overlay. Values are alpha out of 255.
Tint :: enum u8 {
	Subtle,
	Light,
	Medium,
	Strong,
}

Surface_Colors :: struct {
	bg:     Color,
	fg:     Color,
	border: Color,
}

// Surfaces that are transparent when at rest, drawing nothing until they are
// interacted with. They are the only surfaces allowed a zero-alpha rest
// background, which is what lets surface_colors assert opacity for the rest.
surface_transparent_at_rest :: proc(surface: Surface) -> bool {
	return surface == .Row || surface == .Button_Ghost
}

// surface_colors resolves a surface class and interaction state to concrete
// colors.
//
// Control flow is centralized here per Tiger Style: this procedure owns the
// composition and the postcondition, while the two switches live in pure leaf
// helpers. Inlining both would put 13 surfaces x 5 states in one body and blow
// the 100-line procedure limit.
surface_colors :: proc(frame: ^Ui_Frame, surface: Surface, state: Visual_State) -> Surface_Colors {
	assert(frame != nil, "surface_colors: nil frame")
	style := ui_frame_theme(frame)
	result := surface_state_apply(style, surface_base(style, surface), surface, state)

	// A surface the user is *interacting with* must be visible, or the
	// feedback the state exists to provide has been lost.
	//
	// Rest and Disabled are the inert states, and for the two
	// transparent-by-design surfaces they must stay transparent: a disabled
	// ghost button that grew a filled background would read as more
	// substantial than a live one. Hover, Pressed and Selected get no such
	// exemption on any surface.
	inert := state == .Rest || state == .Disabled
	if !inert || !surface_transparent_at_rest(surface) {
		assert(result.bg.a > 0, "surface_colors: interactive surface resolved fully transparent")
	}
	assert(result.fg.a > 0, "surface_colors: surface resolved a fully transparent foreground")
	return result
}

// surface_base maps a surface class to its resting colors. Pure leaf: no
// frame, no state, one switch.
@(private)
surface_base :: proc(style: ^Theme, surface: Surface) -> Surface_Colors {
	assert(style != nil, "surface_base: nil theme")
	switch surface {
	case .App:
		return {style.bg_app, style.fg_primary, {}}
	case .Panel:
		return {style.bg_panel, style.fg_primary, style.border_subtle}
	case .Card:
		return {style.bg_tool_card, style.fg_primary, style.border_subtle}
	case .Popup:
		return {style.bg_popup, style.fg_primary, style.border_color}
	case .Input:
		return {style.bg_input, style.fg_primary, style.border_color}
	case .Row:
		return {{}, style.fg_primary, {}}
	case .Chip:
		return {style.bg_chip, style.fg_secondary, {}}
	case .Code:
		return {style.bg_code, style.fg_code_inline, {}}
	case .Table_Header:
		return {style.bg_table_header, style.fg_heading, style.border_subtle}
	case .Button_Primary:
		return {style.button_bg, style.button_text, style.button_bg}
	case .Button_Secondary:
		return {style.bg_active, style.fg_secondary, {}}
	case .Button_Danger:
		return {style.button_danger_bg, style.button_danger_fg, {}}
	case .Button_Ghost:
		return {{}, style.fg_secondary, {}}
	}
	return {style.bg_color, style.fg_primary, {}}
}

// surface_state_apply shifts resting colors into an interaction state. Pure
// leaf: the parent owns composition, this owns only the state switch.
//
// Disabled resolves fg to fg_disabled for *every* surface. That is the single
// fix for the split-brain where buttons dimmed with fg_muted_dim and menus with
// fg_disabled, which made a disabled button and a disabled menu item two
// different colors in the same frame.
@(private)
surface_state_apply :: proc(
	style: ^Theme,
	base: Surface_Colors,
	surface: Surface,
	state: Visual_State,
) -> Surface_Colors {
	assert(style != nil, "surface_state_apply: nil theme")
	result := base
	switch state {
	case .Rest:
		return result
	case .Hover:
		result.bg = surface_hover_bg(style, surface)
		if surface == .Button_Secondary || surface == .Button_Ghost do result.fg = style.fg_primary
		return result
	case .Pressed:
		result.bg = surface_pressed_bg(style, surface)
		return result
	case .Selected:
		result.bg = style.bg_active
		result.fg = style.fg_primary
		return result
	case .Disabled:
		result.fg = style.fg_disabled
		if !surface_transparent_at_rest(surface) do result.bg = style.button_disabled_bg
		result.border = {}
		return result
	}
	return result
}

// surface_hover_bg is split out because the hover tint is the one state where
// the button variants each have a dedicated palette role rather than sharing
// the generic bg_hover.
@(private)
surface_hover_bg :: proc(style: ^Theme, surface: Surface) -> Color {
	assert(style != nil, "surface_hover_bg: nil theme")
	#partial switch surface {
	case .Button_Primary:
		return style.button_hover
	case .Button_Danger:
		return style.button_danger_hover
	case .Chip:
		return style.bg_chip_hover
	case .Card:
		return style.bg_tool_card_hover
	}
	return style.bg_hover
}

// surface_pressed_bg keeps the primary button on its dedicated pressed role and
// routes everything else through the generic surface_pressed. Before this
// token, only the primary button had any pressed feedback at all.
@(private)
surface_pressed_bg :: proc(style: ^Theme, surface: Surface) -> Color {
	assert(style != nil, "surface_pressed_bg: nil theme")
	if surface == .Button_Primary do return style.button_pressed
	return style.surface_pressed
}

// radius_pixels resolves a radius token to a scaled pixel radius. Kept
// separate from radius_ratio because a caller drawing its own geometry (a tape
// strip, a dog ear) needs the pixel value, not the rect-relative ratio the
// rounded-rect primitive wants.
radius_pixels :: proc(frame: ^Ui_Frame, radius: Radius, min_dimension: f32) -> f32 {
	assert(frame != nil, "radius_pixels: nil frame")
	assert(min_dimension >= 0, "radius_pixels: negative dimension")
	base := ui_frame_metrics(frame).CARD_RADIUS_PX
	assert(base > 0, "radius_pixels: metrics carry a non-positive card radius")
	switch radius {
	case .None:
		return 0
	case .SM:
		return base * 0.5
	case .MD:
		return base
	case .LG:
		return base * 1.75
	case .Pill:
		return min_dimension * 0.5
	}
	return base
}

// radius_ratio converts a radius token to the 0..1 form draw_rectangle_rounded
// expects, given the rect it will be drawn into.
//
// This is the calculation that lets a button and an adjacent card of equal
// height finally agree: both ask for the same absolute radius and both convert
// it against their own geometry, where previously one used a fixed ratio and
// the other a fixed pixel count.
radius_ratio :: proc(frame: ^Ui_Frame, radius: Radius, rect: Rectangle) -> f32 {
	assert(frame != nil, "radius_ratio: nil frame")
	min_dimension := min(rect.width, rect.height)
	if min_dimension <= 0 do return 0
	ratio := (radius_pixels(frame, radius, min_dimension) * 2) / min_dimension
	ratio = clamp(ratio, 0, 1)
	assert(ratio >= 0 && ratio <= 1, "radius_ratio: ratio outside the unit range")
	return ratio
}

// RADIUS_SEGMENTS_MIN keeps a small corner from degenerating into a visible
// chamfer; RADIUS_SEGMENTS_MAX bounds the per-corner vertex cost, since a
// rounded rect emits segments per corner and a large card would otherwise pay
// for curvature nobody can see.
RADIUS_SEGMENTS_MIN :: 4
RADIUS_SEGMENTS_MAX :: 16

// radius_segments picks a corner tessellation from the resolved pixel radius,
// so segment count follows UI scale instead of being a per-call-site constant
// that drifts between widgets.
radius_segments :: proc(radius_px: f32) -> i32 {
	assert(radius_px >= 0, "radius_segments: negative radius")
	segments := i32(radius_px * 0.5) + RADIUS_SEGMENTS_MIN
	return clamp(segments, RADIUS_SEGMENTS_MIN, RADIUS_SEGMENTS_MAX)
}

// border_pixels resolves a border token to a scaled thickness. Every border in
// the library passes through here, which is the whole point: it is the single
// place DPI scaling is applied, so it cannot be forgotten at one call site and
// applied at another.
border_pixels :: proc(frame: ^Ui_Frame, border: Border) -> f32 {
	assert(frame != nil, "border_pixels: nil frame")
	logical: f32
	switch border {
	case .None:
		return 0
	case .Hairline:
		logical = 1
	case .Emphasis:
		logical = 2
	case .Ink:
		logical = 3
	}
	thickness := ui_frame_scf(frame, logical)
	// A border narrower than one screen-space pixel is not a thin border, it is
	// an absent one: the rasteriser spreads it at a fraction of its alpha and it
	// reads as nothing. At 0.75 scale this silently erased the notebook rules,
	// and with them every hairline in the interface. The backend may map this
	// floor to multiple framebuffer pixels under HiDPI.
	if thickness < 1 do thickness = 1
	assert(thickness > 0, "border_pixels: scaled a visible border to nothing")
	return thickness
}

// elevation_offset resolves how far a surface's shadow is displaced. Zero for
// Flat, so an unelevated surface costs no draw command at all.
elevation_offset :: proc(frame: ^Ui_Frame, elevation: Elevation) -> f32 {
	assert(frame != nil, "elevation_offset: nil frame")
	logical: f32
	switch elevation {
	case .Flat:
		return 0
	case .Lifted:
		logical = 2
	case .Overlay:
		logical = 4
	case .Modal:
		logical = 6
	}
	return ui_frame_scf(frame, logical)
}

// tint_alpha resolves a tint token to an alpha value.
//
// The four levels are the ones the library already used as bare numbers:
// 18 for a chart's fill wash, 38 for a pill tint, 70 for a scrim over content,
// and 235 for a near-opaque overlay panel. Naming them is what stops a fifth
// from being invented at the next call site.
tint_alpha :: proc(tint: Tint) -> u8 {
	switch tint {
	case .Subtle:
		return 18
	case .Light:
		return 38
	case .Medium:
		return 70
	case .Strong:
		return 235
	}
	return 255
}

// color_tinted re-alphas a color to a named tint level, so a translucent
// overlay keeps its palette hue instead of being rebuilt as a fresh literal.
color_tinted :: proc(color: Color, tint: Tint) -> Color {
	return {color.r, color.g, color.b, tint_alpha(tint)}
}

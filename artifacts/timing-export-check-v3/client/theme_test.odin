package main

import "core:testing"
import fit "ingot:fit"
import uilib "ingot:ui"

// The palette is data, and data drifts. These tests pin the two properties
// that turn a bad colour from a visual annoyance into a crash or an
// unreadable HUD.
//
// ui_runtime_set_theme asserts two contrast pairs at runtime
// (ingot/ui/theme.odin). An assertion there fires inside the host during
// Session_Set_Theme, before a single frame is drawn, so the failure the
// player sees is "the game does not start". Checking the same two pairs
// here moves that failure into `bash build.sh test`.

@(test)
theme_clears_the_contrast_assertions_the_runtime_makes :: proc(t: ^testing.T) {
	style := terra_theme().inner
	primary := uilib.contrast_ratio(style.fg_primary, style.bg_color)
	testing.expectf(
		t,
		primary >= uilib.MIN_TEXT_CONTRAST,
		"fg_primary on bg_color is %.2f:1, below the %.1f:1 ui_runtime_set_theme asserts",
		primary,
		uilib.MIN_TEXT_CONTRAST,
	)
	button := uilib.contrast_ratio(style.button_text, style.button_bg)
	testing.expectf(
		t,
		button >= uilib.MIN_TEXT_CONTRAST,
		"button_text on button_bg is %.2f:1, below the %.1f:1 ui_runtime_set_theme asserts",
		button,
		uilib.MIN_TEXT_CONTRAST,
	)
}

// Panels are drawn on bg_panel, not bg_color, and bg_panel is translucent
// over a 3D world that can be any brightness. Every ink that carries text
// has to clear AA against the panel body too, or a perfectly legal palette
// produces a HUD that is unreadable exactly where the HUD lives.
@(test)
theme_text_inks_are_legible_on_the_panel_body :: proc(t: ^testing.T) {
	style := terra_theme().inner
	// Compare against the opaque panel colour: alpha is a compositing
	// property, and contrast_ratio ignores it by design.
	ground := style.bg_panel
	ground.a = 255
	Case :: struct {
		name:  string,
		color: uilib.Color,
	}
	cases := [?]Case {
		{"fg_primary", style.fg_primary},
		{"fg_heading", style.fg_heading},
		{"fg_secondary", style.fg_secondary},
		{"fg_accent", style.fg_accent},
		{"fg_tool", style.fg_tool},
		{"fg_error", style.fg_error},
		{"fg_success", style.fg_success},
	}
	for item in cases {
		ratio := uilib.contrast_ratio(item.color, ground)
		testing.expectf(
			t,
			ratio >= uilib.MIN_TEXT_CONTRAST,
			"%s on bg_panel is %.2f:1, below %.1f:1",
			item.name,
			ratio,
			uilib.MIN_TEXT_CONTRAST,
		)
	}
}

// A role left at zero alpha draws nothing at all, which is invisible in
// review and only shows up as a missing widget in one interaction state.
// The dark theme this palette derives from has every role set, so a zero
// here means an override wrote one by accident.
@(test)
theme_leaves_no_paint_role_transparent :: proc(t: ^testing.T) {
	style := terra_theme().inner
	Case :: struct {
		name:  string,
		color: uilib.Color,
	}
	cases := [?]Case {
		{"bg_color", style.bg_color},
		{"bg_panel", style.bg_panel},
		{"bg_popup", style.bg_popup},
		{"bg_active", style.bg_active},
		{"bg_hover", style.bg_hover},
		{"bg_input", style.bg_input},
		{"button_bg", style.button_bg},
		{"button_hover", style.button_hover},
		{"button_pressed", style.button_pressed},
		{"button_text", style.button_text},
		{"surface_pressed", style.surface_pressed},
		{"border_color", style.border_color},
		{"border_subtle", style.border_subtle},
		{"focus_ring", style.focus_ring},
		{"modal_dim", style.modal_dim},
		{"fg_disabled", style.fg_disabled},
		{"fg_label", style.fg_label},
		{"fg_on_accent", style.fg_on_accent},
		{"caption_hover", style.caption_hover},
		{"caption_close_hover", style.caption_close_hover},
	}
	for item in cases {
		testing.expectf(t, item.color.a > 0, "%s is fully transparent", item.name)
	}
}

// The interaction states have to be distinguishable, or a button gives no
// feedback the player can see. This is the failure the high-contrast theme
// upstream shipped with (pressed identical to hover) and it is cheap to pin.
@(test)
theme_button_states_are_distinguishable :: proc(t: ^testing.T) {
	style := terra_theme().inner
	testing.expect(t, style.button_bg != style.button_hover, "button hover matches rest")
	testing.expect(t, style.button_hover != style.button_pressed, "button pressed matches hover")
	testing.expect(t, style.bg_hover != style.surface_pressed, "surface pressed matches hover")
	testing.expect(
		t,
		style.caption_hover != style.caption_pressed,
		"caption pressed matches hover",
	)
}

// Amber is the palette's one non-phosphor information channel: it means
// cost or warning and nothing else. If it ever equals the phosphor accent
// the distinction the HUD relies on has silently collapsed.
@(test)
theme_reserves_amber_for_cost_and_warning :: proc(t: ^testing.T) {
	style := terra_theme().inner
	testing.expect(
		t,
		style.fg_tool != style.fg_accent,
		"amber cost ink equals the phosphor accent",
	)
	testing.expect(t, style.fg_error != style.fg_accent, "danger ink equals the phosphor accent")
	testing.expect(
		t,
		fit.Color(style.fg_tool) == fit.Color(UI_AMBER),
		"fg_tool drifted from UI_AMBER",
	)
	testing.expect(
		t,
		fit.Color(style.fg_error) == fit.Color(UI_DANGER),
		"fg_error drifted from UI_DANGER",
	)
	testing.expect(
		t,
		UI_DEBUG_MARKER_SHADOW.a > UI_DEBUG_SCOPE.a,
		"marker shadow is too transparent",
	)
	testing.expect(t, UI_DEBUG_MARKER_SHADOW != UI_AMBER, "marker shadow collapsed into amber")
	testing.expect(t, UI_DEBUG_AXIS_X == UI_DANGER, "debug X axis left the danger channel")
	testing.expect(t, UI_DEBUG_AXIS_Y == UI_GLOW, "debug Y axis left the phosphor channel")
	testing.expect(t, UI_DEBUG_AXIS_Z == UI_TERRAFORM_LEVEL, "debug Z axis left the survey channel")
	testing.expect(t, UI_DEBUG_AXIS_X != UI_DEBUG_AXIS_Y, "debug X and Y axes are indistinguishable")
	testing.expect(t, UI_DEBUG_AXIS_X != UI_DEBUG_AXIS_Z, "debug X and Z axes are indistinguishable")
	testing.expect(t, UI_DEBUG_AXIS_Y != UI_DEBUG_AXIS_Z, "debug Y and Z axes are indistinguishable")
	testing.expect(t, UI_DEBUG_AXIS_X != UI_DEBUG_MARKER_SHADOW, "debug X axis collapsed into shadow")
	testing.expect(t, UI_DEBUG_AXIS_Y != UI_DEBUG_MARKER_SHADOW, "debug Y axis collapsed into shadow")
	testing.expect(t, UI_DEBUG_AXIS_Z != UI_DEBUG_MARKER_SHADOW, "debug Z axis collapsed into shadow")
	testing.expect(t, UI_DEBUG_AXIS_X != UI_AMBER, "debug X axis consumed reserved amber")
	testing.expect(t, UI_DEBUG_AXIS_Y != UI_AMBER, "debug Y axis consumed reserved amber")
	testing.expect(t, UI_DEBUG_AXIS_Z != UI_AMBER, "debug Z axis consumed reserved amber")
}

// The scanline pitch has to stay under fit's own rule bound at every scale
// and panel height the game can produce, including a full-height console on
// a 4K display. fit.Draw_Rules asserts rather than truncating, so a pitch
// that is too fine is a crash, not a cosmetic issue.
@(test)
theme_scanline_pitch_stays_under_the_rule_bound :: proc(t: ^testing.T) {
	heights := [?]i32{40, 120, 540, 1080, 2160, 4320}
	scales := [?]f32{0.5, 1.0, 1.5, 2.0, 3.0}
	for height in heights {
		for scale in scales {
			pitch := max(ui_px(scale, UI_SCANLINE_PITCH), 1)
			pitch = max(pitch, height / UI_SCANLINE_MAX + 1)
			count := height / pitch
			testing.expectf(
				t,
				count <= UI_SCANLINE_MAX,
				"a %d px panel at scale %v needs %d rules against a bound of %d",
				height,
				scale,
				count,
				UI_SCANLINE_MAX,
			)
		}
	}
}

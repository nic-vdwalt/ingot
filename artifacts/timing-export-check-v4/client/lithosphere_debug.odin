package main

import shared "../shared"
import rl "ingot:gfx"

LITHOSPHERE_DEBUG_WIDGET :: u32(0x4c495448)
PLANET_CUTAWAY_DEBUG_WIDGET :: u32(0x43555441)
TECTONIC_TIMELAPSE_WIDGET :: u32(0x54494d45)
TECTONIC_STEP_WIDGET :: u32(0x53544550)

lithosphere_debug_color :: proc(
	crust: shared.Plate_Crust,
	boundary: shared.Plate_Boundary,
	boundary_strength: u8,
) -> rl.Color {
	color := UI_LITHOSPHERE_OCEANIC
	if crust == .Continental do color = UI_LITHOSPHERE_CONTINENTAL
	accent := UI_LITHOSPHERE_BOUNDARY
	switch boundary {
	case .Subduction: accent = UI_LITHOSPHERE_SUBDUCTION
	case .Collision: accent = UI_LITHOSPHERE_COLLISION
	case .Ridge: accent = UI_LITHOSPHERE_RIDGE
	case .Transform: accent = UI_LITHOSPHERE_TRANSFORM
	case .Intraplate:
	}
	blend := f32(boundary_strength) / 255
	if boundary != .Intraplate && blend > 0.35 {
		blend = (blend - 0.35) / 0.65 * 0.7
		color.r = u8(f32(color.r) + (f32(accent.r) - f32(color.r)) * blend)
		color.g = u8(f32(color.g) + (f32(accent.g) - f32(color.g)) * blend)
		color.b = u8(f32(color.b) + (f32(accent.b) - f32(color.b)) * blend)
	}
	return color
}

lithosphere_debug_extension :: proc(value: ^Client_State, panel: ^Debug_Panel_Extension_Context) {
	assert(value != nil && panel != nil, "lithosphere debug extension: nil input")
	if debug_panel_extension_checkbox(
		panel,
		LITHOSPHERE_DEBUG_WIDGET,
		"lithosphere overlay",
		&value.lithosphere_debug,
	) {
		value.lithosphere_debug_revision += 1
	}
	_ = debug_panel_extension_checkbox(
		panel,
		PLANET_CUTAWAY_DEBUG_WIDGET,
		"planet cutaway",
		&value.planet_cutaway,
	)
	time_lapse := value.world.planetary.tectonics.mode == .Time_Lapse
	if debug_panel_extension_checkbox(
		panel,
		TECTONIC_TIMELAPSE_WIDGET,
		"geological time-lapse",
		&time_lapse,
	) {
		value.world.planetary.tectonics.mode = .Time_Lapse if time_lapse else .Normal
		shared.planetary_mark_mutated(&value.world.planetary)
	}
	if debug_panel_extension_button(panel, TECTONIC_STEP_WIDGET, "advance tectonic epoch") {
		shared.planetary_mark_mutated(&value.world.planetary)
		_ = shared.planetary_geological_step(&value.world, shared.TECTONIC_TIMELAPSE_YEARS_PER_STEP)
	}
}

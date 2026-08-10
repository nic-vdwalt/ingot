// examples/box3d_water - the water model itself. It is kept in its own file,
// free of `ingot:gfx` and `vendor:box3d`, because every procedure here is pure:
// the same inputs must produce the same outputs whether they are called from
// the render loop, the fixed simulation step, or a headless test. That is what
// lets `water_test.odin` act as the oracle for the physics without a GPU, a
// window, or a Box3D world.
//
// Box3D is a rigid-body solver, not a fluid solver. It has no concept of water,
// so the surface below is an analytical wave the application owns, and the only
// thing handed to Box3D is a force. That division is the entire point of the
// example: waves stay cheap and deterministic here, while buoyancy response,
// contacts, and integration stay with the solver.
package main

import "core:math"

// The surface is the sum of two sine waves travelling along X and Y. One wave
// alone reads as a rolling ramp from most camera angles; the second, at a
// different wavelength and phase rate, breaks that regularity without needing a
// noise field or a per-frame mesh rebuild.
WATER_BASE_Z :: f32(0)
WATER_AMPLITUDE :: f32(0.75)
WATER_WAVE_NUMBER_X :: f32(0.55)
WATER_WAVE_NUMBER_Y :: f32(0.38)
WATER_CROSS_AMPLITUDE :: WATER_AMPLITUDE * 0.5
WATER_CROSS_PHASE_RATE :: f32(1.3)

// Phase advances by this rate times the fixed timestep, never by wall-clock
// time, so pausing the simulation freezes the water exactly as it freezes the
// bodies and a single step advances both by one deterministic increment.
WATER_PHASE_RATE :: f32(1.6)

// The phase at which the whole surface repeats, so it can be folded without
// introducing a discontinuity. It is not TAU: the cross wave runs at 13/10 of
// the primary phase, so both terms only return to their starting angle after
// ten primary cycles. Folding at TAU instead would jump the cross wave by
// 0.3 * TAU and teleport the water - and therefore the buoyancy - mid-run.
WATER_PHASE_PERIOD :: f32(10 * math.TAU)

// The largest displacement the two waves can reach together. The mesh bounds
// and the tests are both derived from it, so changing either amplitude without
// revisiting the bound fails loudly instead of clipping geometry silently.
WATER_HEIGHT_SPAN :: WATER_AMPLITUDE + WATER_CROSS_AMPLITUDE

// Buoyancy is expressed as a multiple of the body's own weight at full
// immersion. A gain of exactly 1 leaves a fully submerged body neutrally
// buoyant so it never returns to the surface; 1.6 puts equilibrium at roughly
// 62% immersion, which floats visibly without launching the body into the air.
WATER_BUOYANCY_GAIN :: f32(1.6)
WATER_GRAVITY :: f32(10)

// Linear drag, in inverse seconds, applied only to the submerged fraction.
// Water resists motion far more than air, and without this term the body
// oscillates forever on the spring the buoyancy force describes.
WATER_DRAG :: f32(3.0)

// A hard ceiling on any single force component. Buoyancy and drag are both
// bounded by construction, so reaching this means a caller passed a nonsensical
// mass or velocity; clamping keeps one bad frame from flinging a body out of
// the world before the next frame can correct it.
WATER_FORCE_MAX :: f32(4000)

// water_height evaluates the surface at a world XY position for a given phase.
// Phase, not time, is the parameter: the caller decides when the simulation
// advances, so a paused world simply keeps passing the same phase.
water_height :: proc(x, y, phase: f32) -> f32 {
	assert(!math.is_nan(x) && !math.is_nan(y), "water_height: non-finite position")
	assert(!math.is_nan(phase), "water_height: non-finite phase")
	primary := WATER_AMPLITUDE * math.sin(WATER_WAVE_NUMBER_X * x + phase)
	cross_angle := WATER_WAVE_NUMBER_Y * y + WATER_CROSS_PHASE_RATE * phase
	cross := WATER_CROSS_AMPLITUDE * math.sin(cross_angle)
	return WATER_BASE_Z + primary + cross
}

// water_surface_velocity is the analytical time derivative of water_height.
// Drag has to resist motion relative to the water rather than relative to the
// world, or a body riding a rising crest is damped as though the water were
// still and the float looks glued in place.
water_surface_velocity :: proc(x, y, phase: f32) -> f32 {
	assert(!math.is_nan(x) && !math.is_nan(y), "water_surface_velocity: bad position")
	assert(!math.is_nan(phase), "water_surface_velocity: non-finite phase")
	primary := WATER_AMPLITUDE * WATER_PHASE_RATE
	primary *= math.cos(WATER_WAVE_NUMBER_X * x + phase)
	cross_rate := WATER_CROSS_AMPLITUDE * WATER_CROSS_PHASE_RATE * WATER_PHASE_RATE
	cross_angle := WATER_WAVE_NUMBER_Y * y + WATER_CROSS_PHASE_RATE * phase
	return primary + cross_rate * math.cos(cross_angle)
}

// water_normal returns the unit surface normal from the analytical slopes. The
// mesh is uploaded once, so lighting has to come from the exact derivative
// rather than from cross products over neighbouring triangles.
water_normal :: proc(x, y, phase: f32) -> [3]f32 {
	assert(!math.is_nan(x) && !math.is_nan(y), "water_normal: non-finite position")
	assert(!math.is_nan(phase), "water_normal: non-finite phase")
	slope_x := WATER_AMPLITUDE * WATER_WAVE_NUMBER_X
	slope_x *= math.cos(WATER_WAVE_NUMBER_X * x + phase)
	cross_angle := WATER_WAVE_NUMBER_Y * y + WATER_CROSS_PHASE_RATE * phase
	slope_y := WATER_CROSS_AMPLITUDE * WATER_WAVE_NUMBER_Y * math.cos(cross_angle)
	normal := [3]f32{-slope_x, -slope_y, 1}
	length := math.sqrt(normal.x * normal.x + normal.y * normal.y + 1)
	assert(length >= 1, "water_normal: degenerate slope length")
	return normal / length
}

// water_submerged_fraction reports how much of a box of half-height
// `half_height`, centred at `center_z`, lies below `water_z`. Returning a
// fraction rather than a depth is what keeps the force law independent of the
// body's size: the caller multiplies it by the body's own weight.
water_submerged_fraction :: proc(center_z, half_height, water_z: f32) -> f32 {
	assert(!math.is_nan(center_z), "water_submerged_fraction: non-finite centre")
	assert(!math.is_nan(water_z), "water_submerged_fraction: non-finite surface")
	if half_height <= 0 do return 0
	bottom := center_z - half_height
	top := center_z + half_height
	if water_z <= bottom do return 0
	if water_z >= top do return 1
	fraction := (water_z - bottom) / (2 * half_height)
	assert(fraction >= 0 && fraction <= 1, "water_submerged_fraction: out of range")
	return fraction
}

// water_force returns the buoyancy and drag force to apply at a body's centre
// of mass. Both terms scale with the submerged fraction, so a body clear of the
// surface receives exactly zero and a fully submerged one receives the full
// restoring force. Drag opposes velocity relative to the moving surface.
water_force :: proc(
	center_z, half_height, mass, water_z, water_velocity_z: f32,
	velocity: [3]f32,
) -> [3]f32 {
	assert(half_height >= 0, "water_force: negative half height")
	assert(!math.is_nan(water_velocity_z), "water_force: non-finite surface speed")
	if mass <= 0 do return {}
	submerged := water_submerged_fraction(center_z, half_height, water_z)
	if submerged <= 0 do return {}
	buoyancy := submerged * mass * WATER_GRAVITY * WATER_BUOYANCY_GAIN
	relative := velocity - [3]f32{0, 0, water_velocity_z}
	drag := -WATER_DRAG * mass * submerged * relative
	force := [3]f32{drag.x, drag.y, drag.z + buoyancy}
	for &component in force {
		component = clamp(component, -WATER_FORCE_MAX, WATER_FORCE_MAX)
	}
	return force
}

package main

import "core:testing"
import "core:math"
import "core:math/linalg"
import shared "../shared"

@(test)
planet_camera_visual_transition_is_continuous :: proc(t: ^testing.T) {
	surface := planet_camera_visual_context({0, 0, 1120}, {0, 0, 1080}, PLANET_SURFACE_ZOOM, 42, 720)
	blend := planet_camera_visual_context({0, 0, 1360}, {0, 0, 1080}, PLANET_SURFACE_ZOOM * 1.25, 42, 720)
	orbit := planet_camera_visual_context({0, 0, 1800}, {0, 0, 0}, PLANET_SURFACE_ZOOM * 1.5, 42, 720)
	testing.expect(t, surface.close_weight <= 0.001)
	testing.expect(t, surface.regional_weight > 0.99)
	testing.expect(t, blend.overview_weight > 0 && blend.overview_weight < 1)
	testing.expect(t, orbit.overview_weight > 0.99)
	contexts := [?]Camera_Visual_Context{surface, blend, orbit}
	for visual in contexts {
		testing.expect(t, abs(visual.close_weight + visual.regional_weight + visual.overview_weight - 1) < 0.0001)
	}
}

// Space and Shift move the player's lift above the seated orbit pivot, so the
// camera rises and falls without the view direction changing. The rate is a
// pure function of the two key states, the orbit distance, and the frame
// step, and the seating rules are pure functions of a surface height and that
// lift, which is what makes the sign, the symmetry, the distance scaling and
// the pivot placement checkable without a window - Client_State is ~183 MB and
// owns a GPU, so no test here may touch it.

// A frame where neither key is down must cost nothing, and a frame where both
// are down must cancel rather than pick a winner: holding Shift to resize the
// brush while Space is down should not drift the camera either way.
@(test)
camera_elevation_is_zero_without_a_clear_intent :: proc(t: ^testing.T) {
	testing.expect_value(t, camera_elevation_delta(false, false, 60, 1.0 / 60), 0)
	testing.expect_value(t, camera_elevation_delta(true, true, 60, 1.0 / 60), 0)
}

// Space lifts and Shift drops by the same amount. An asymmetry would mean a
// player who rose and then descended for the same number of frames did not
// return to the height they started at.
@(test)
camera_elevation_is_signed_and_symmetric :: proc(t: ^testing.T) {
	up := camera_elevation_delta(true, false, 60, 1.0 / 60)
	down := camera_elevation_delta(false, true, 60, 1.0 / 60)
	testing.expect(t, up > 0, "space must raise the camera")
	testing.expect(t, down < 0, "shift must lower the camera")
	testing.expect_value(t, up, -down)
}

// The rate scales with orbit distance for the same reason keyboard pan does:
// a lift covers the same fraction of the screen zoomed in as zoomed out.
@(test)
camera_elevation_scales_with_orbit_distance :: proc(t: ^testing.T) {
	near := camera_elevation_delta(true, false, 30, 1.0 / 60)
	far := camera_elevation_delta(true, false, 120, 1.0 / 60)
	testing.expect(t, far > near, "a zoomed-out camera must lift faster")
	testing.expect_value(t, far, near * 4)
}

// Frame rate must not change how far a held key travels per second, or the
// camera would climb faster on a fast machine than on a slow one.
@(test)
camera_elevation_scales_with_frame_time :: proc(t: ^testing.T) {
	short := camera_elevation_delta(true, false, 60, 1.0 / 120)
	long := camera_elevation_delta(true, false, 60, 1.0 / 60)
	testing.expect_value(t, long, short * 2)
	testing.expect_value(t, camera_elevation_delta(true, false, 60, 0), 0)
}

// The clamp band has to bracket the world surface: a floor above zero would
// shove the target up off flat ground on the first frame, and a ceiling below
// it would forbid rising at all.
@(test)
camera_elevation_band_brackets_the_surface :: proc(t: ^testing.T) {
	testing.expect(t, CAMERA_MIN_ELEVATION < 0, "the elevation floor must sit below sea level")
	testing.expect(t, CAMERA_MAX_ELEVATION > 0, "the elevation ceiling must sit above sea level")
	// The ceiling stays within the zoom-out band so a raised camera cannot
	// climb outside the decoration streaming window and reveal flora pop-in.
	testing.expect(
		t,
		CAMERA_MAX_ELEVATION <= CAMERA_MAX_DISTANCE,
		"the elevation ceiling must stay inside the streaming window",
	)
	// The default start height must already be legal, or camera_reset would
	// be corrected by the clamp on the very first frame.
	testing.expect(
		t,
		CAMERA_MIN_ELEVATION <= 0 && 0 <= CAMERA_MAX_ELEVATION,
		"the reset target height must be inside the band",
	)
}

// The pivot sits on the surface it orbits. camera_reset can only aim at z = 0
// — it runs before any terrain exists — and `map regenerate random` puts
// anything from an ocean floor to an alpine summit under the world centre, so
// a pivot that ignored the surface rotated the view around a point inside the
// hill and pitch stopped agreeing with what was on screen.
@(test)
camera_pivot_sits_on_the_surface :: proc(t: ^testing.T) {
	testing.expect_value(t, camera_pivot_height(0, 0), 0)
	testing.expect_value(t, camera_pivot_height(32.5, 0), 32.5)
	testing.expect_value(t, camera_pivot_height(-8.75, 0), -8.75)
	testing.expect_value(t, camera_pivot_height(12, 8), 20)
}

// The band still governs the seated pivot: an alpine summit plus a full lift
// may not climb past the ceiling that keeps the eye inside the decoration
// streaming window, and the floor holds under the deepest sea bed.
@(test)
camera_pivot_stays_inside_the_elevation_band :: proc(t: ^testing.T) {
	testing.expect_value(
		t,
		camera_pivot_height(CAMERA_MAX_ELEVATION, CAMERA_MAX_ELEVATION),
		CAMERA_MAX_ELEVATION,
	)
	testing.expect_value(t, camera_pivot_height(CAMERA_MIN_ELEVATION - 100, 0), CAMERA_MIN_ELEVATION)
}

// Space and Shift move a lift above the surface, not the pivot itself: the
// pivot is re-seated every frame, so a raw target offset would be overwritten.
// The lift may never go negative — that is exactly the buried pivot the
// seating exists to prevent — and it stops at the band ceiling.
@(test)
camera_elevation_offset_never_sinks_below_the_surface :: proc(t: ^testing.T) {
	testing.expect_value(t, camera_elevation_offset_next(0, -5), 0)
	testing.expect_value(t, camera_elevation_offset_next(3, -5), 0)
	testing.expect_value(t, camera_elevation_offset_next(3, 5), 8)
	testing.expect_value(
		t,
		camera_elevation_offset_next(CAMERA_MAX_ELEVATION, 10),
		CAMERA_MAX_ELEVATION,
	)
}

// A submerged pivot seats on the water top, not the sea bed. An ocean centre
// is one of the eight documented seed starts, and seating on the bed put the
// eye under the sea surface with the whole translucent water grid filling the
// frame. Dry ground must be left exactly where it is.
@(test)
camera_surface_rises_to_the_water_top :: proc(t: ^testing.T) {
	testing.expect_value(t, camera_water_surface(7, 0), f32(7))
	bed := f32(-8.75)
	flooded := camera_water_surface(bed, 6)
	testing.expect(t, flooded > bed, "a submerged pivot must seat on the water surface")
	surface, _, _ := water_render_sample(bed, 6)
	testing.expect_value(t, flooded, surface)
	// A trace of water is not a surface to sit on: below the wet threshold
	// the cell renders dry, so the ground stays the seat.
	testing.expect_value(t, camera_water_surface(7, -1), f32(7))
}

// The pivot eases onto its seat instead of snapping there every frame. Grab
// pan re-solves the cursor ray each frame, so an instant seat would feed its
// own height change back into the pan; the ease must therefore close only
// part of the gap in one frame, never overshoot, and never move away from the
// seat.
@(test)
camera_pivot_follow_closes_the_gap_without_overshooting :: proc(t: ^testing.T) {
	step := f32(1.0 / 60)
	eased := camera_pivot_follow(0, 20, step)
	testing.expect(t, eased > 0, "the pivot must move toward its seat")
	testing.expect(t, eased < 20, "one frame must not snap the pivot onto its seat")
	longer := camera_pivot_follow(0, 20, 4 * step)
	testing.expect(t, longer > eased, "a longer frame must close more of the gap")
	falling := camera_pivot_follow(20, 0, step)
	testing.expect(t, falling < 20 && falling > 0, "the ease must work downhill too")
	testing.expect_value(t, camera_pivot_follow(5, 5, step), f32(5))
}

// A zero step snaps: the loading transition seats the camera on a map that
// has no previous frame to ease from, and must hand gameplay a camera that
// already looks at the surface rather than easing onto it in view.
@(test)
camera_pivot_follow_snaps_without_a_frame_step :: proc(t: ^testing.T) {
	testing.expect_value(t, camera_pivot_follow(0, 32.5, 0), f32(32.5))
	testing.expect_value(t, camera_pivot_follow(100, -8.75, 0), f32(-8.75))
	// However long the frame, the ease may not pass the seat: an overshoot
	// would put the pivot back under the surface it is climbing onto.
	testing.expect(t, camera_pivot_follow(0, 20, 10) <= 20, "the ease must not overshoot")
}

// One scroll notch keeps a fixed fraction of the distance, so zooming is a
// geometric walk: the same notch count covers the same ratio from orbit as
// from ground level, where the library's fixed step needed ~1900 notches.
@(test)
camera_zoom_is_multiplicative :: proc(t: ^testing.T) {
	far := camera_zoom_next(3600, 1)
	near := camera_zoom_next(36, 1)
	testing.expect_value(t, far / 3600, near / 36)
	testing.expect(t, far < 3600, "scrolling in must shorten the distance")
	testing.expect(t, camera_zoom_next(60, -1) > 60, "scrolling out must lengthen it")
}

// The zoom curve honours the same clamps the orbit config enforces, so the
// custom path can never carry the eye through the surface or past the
// zoom-out ceiling.
@(test)
camera_zoom_respects_the_distance_band :: proc(t: ^testing.T) {
	testing.expect_value(t, camera_zoom_next(CAMERA_MIN_DISTANCE, 5), CAMERA_MIN_DISTANCE)
	testing.expect_value(t, camera_zoom_next(CAMERA_MAX_DISTANCE, -5), CAMERA_MAX_DISTANCE)
}

// A thrown globe slows exponentially and comes to an actual stop: the decay
// must be monotonic, cost nothing on a zero step, and snap to zero below
// the floor rather than spinning imperceptibly forever.
@(test)
camera_spin_decays_to_rest :: proc(t: ^testing.T) {
	step := f32(1.0 / 60)
	slower := camera_spin_next(2, step)
	testing.expect(t, slower < 2, "a frame must slow the throw")
	testing.expect(t, slower > 0, "one frame must not stop a fast throw")
	testing.expect_value(t, camera_spin_next(2, 0), 2)
	testing.expect_value(t, camera_spin_next(CAMERA_SPIN_MIN_SPEED * 0.9, step), 0)
}

@(test)
camera_surface_frame_is_orthonormal_and_right_handed :: proc(t: ^testing.T) {
	radials := [][3]f32 {
		linalg.normalize([3]f32{0.3, 0.2, 0.9}),
		linalg.normalize([3]f32{-0.7, 0.1, 0.4}),
		linalg.normalize([3]f32{0.5, -0.6, -0.2}),
	}
	for radial in radials {
		up, east, north := _camera_surface_frame(radial, {0, 0, 1})
		testing.expect(t, abs(linalg.length(up) - 1) < 0.001, "up unit")
		testing.expect(t, abs(linalg.length(east) - 1) < 0.001, "east unit")
		testing.expect(t, abs(linalg.length(north) - 1) < 0.001, "north unit")
		testing.expect(t, abs(linalg.dot(up, east)) < 0.001, "up perp east")
		testing.expect(t, abs(linalg.dot(up, north)) < 0.001, "up perp north")
		testing.expect(t, abs(linalg.dot(east, north)) < 0.001, "east perp north")
		expected_north := _camera_cross(up, east)
		testing.expect(t, linalg.length(north - expected_north) < 0.001, "right handed")
	}
}

@(test)
camera_surface_frame_transports_continuously_across_the_pole :: proc(t: ^testing.T) {
	radial := [3]f32{1, 0, 0}
	east := [3]f32{0, 0, -1}
	previous_east := east
	crossed := false
	for step in 0 ..< 8 {
		radial, east = camera_surface_rotate(radial, east, {0, 0, 1}, math.PI / 8)
		up, frame_east, north := _camera_surface_frame(radial, east)
		testing.expect(t, abs(linalg.length(up) - 1) < 0.001, "up unit at pole")
		testing.expect(t, abs(linalg.length(frame_east) - 1) < 0.001, "east unit at pole")
		testing.expect(t, abs(linalg.length(north) - 1) < 0.001, "north unit at pole")
		testing.expect(t, abs(linalg.dot(up, frame_east)) < 0.001, "frame tangent at pole")
		testing.expect(t, linalg.dot(previous_east, frame_east) > 0.99, "east must not flip")
		if step >= 4 && radial.x < 0 do crossed = true
		previous_east = frame_east
	}
	testing.expect(t, crossed, "movement must cross the pole")
}

@(test)
camera_surface_rotation_is_reversible_and_step_independent :: proc(t: ^testing.T) {
	radial := linalg.normalize([3]f32{0.7, -0.2, 0.5})
	_, east, _ := _camera_surface_frame(radial, {0, 0, 1})
	axis := linalg.normalize([3]f32{0.2, 0.8, -0.5})
	angle := f32(1.3)
	one_radial, one_east := camera_surface_rotate(radial, east, axis, angle)
	many_radial, many_east := radial, east
	for _ in 0 ..< 60 {
		many_radial, many_east = camera_surface_rotate(many_radial, many_east, axis, angle / 60)
	}
	testing.expect(t, linalg.length(one_radial - many_radial) < 0.001, "rotation radial step independent")
	testing.expect(t, linalg.length(one_east - many_east) < 0.001, "rotation east step independent")
	restored_radial, restored_east := camera_surface_rotate(one_radial, one_east, axis, -angle)
	testing.expect(t, linalg.length(restored_radial - radial) < 0.001, "inverse restores radial")
	testing.expect(t, linalg.length(restored_east - east) < 0.001, "inverse restores east")
}

@(test)
camera_spherical_pan_intent_cancels_and_normalizes :: proc(t: ^testing.T) {
	testing.expect_value(t, camera_spherical_pan_intent(true, true, true, true), [2]f32{})
	diagonal := camera_spherical_pan_intent(true, false, true, false)
	testing.expect(t, abs(linalg.length(diagonal) - 1) < 0.001, "diagonal intent unit")
	testing.expect(t, diagonal.x > 0 && diagonal.y > 0, "diagonal intent signed")
}

@(test)
camera_spherical_pan_tracks_screen_forward :: proc(t: ^testing.T) {
	radials := [][3]f32 {
		linalg.normalize([3]f32{1, 0.2, 0.1}),
		linalg.normalize([3]f32{-0.4, 0.3, 0.8}),
		linalg.normalize([3]f32{0.01, 1, 0.01}),
	}
	yaws := []f32{0, math.PI / 2, -math.PI / 2, CAMERA_START_YAW}
	for start in radials {
		for yaw in yaws {
			target := start * f32(shared.PLANET_RADIUS)
			_, east, _ := _camera_surface_frame(start, {0, 0, 1})
			for _ in 0 ..< 256 {
				radial, frame_east, north := _camera_surface_frame(target, east)
				forward := -frame_east * math.cos(yaw) - north * math.sin(yaw)
				right := north * math.cos(yaw) - frame_east * math.sin(yaw)
				next, next_east := camera_spherical_pan_next(target, east, yaw, {0, 1}, 60, 1.0 / 60)
				delta := linalg.normalize(next) - radial
				testing.expect(t, linalg.dot(delta, forward) > 0, "forward step aligned")
				testing.expect(t, abs(linalg.dot(delta, right)) < 0.0001, "forward step not lateral")
				testing.expect(t, abs(linalg.length(next) - linalg.length(target)) < 0.001, "radius preserved")
				target, east = next, next_east
			}
		}
	}
}

@(test)
camera_spherical_pan_completes_a_closed_great_circle :: proc(t: ^testing.T) {
	start := [3]f32{shared.PLANET_RADIUS, 0, 0}
	start_east := [3]f32{0, 0, -1}
	target, east := start, start_east
	steps := 720
	frame_dt := f32(2 * math.PI / f32(steps) / CAMERA_PAN_SPEED)
	for _ in 0 ..< steps {
		target, east = camera_spherical_pan_next(
			target,
			east,
			-math.PI / 2,
			{0, 1},
			shared.PLANET_RADIUS,
			frame_dt,
		)
		testing.expect(t, abs(target.z) < 0.01, "held W must stay on one great circle")
	}
	testing.expect(t, linalg.length(target - start) < 0.1, "one revolution restores target")
	testing.expect(t, linalg.length(east - start_east) < 0.001, "one revolution restores orientation")
}

@(test)
camera_spherical_pan_is_frame_rate_independent :: proc(t: ^testing.T) {
	start := linalg.normalize([3]f32{0.7, -0.2, 0.5}) * f32(shared.PLANET_RADIUS)
	_, start_east, _ := _camera_surface_frame(start, {0, 0, 1})
	one, one_east := camera_spherical_pan_next(start, start_east, 0.3, {0, 1}, 60, 1)
	many, many_east := start, start_east
	for _ in 0 ..< 60 {
		many, many_east = camera_spherical_pan_next(many, many_east, 0.3, {0, 1}, 60, 1.0 / 60)
	}
	testing.expect(t, linalg.length(linalg.normalize(one) - linalg.normalize(many)) < 0.001)
	testing.expect(t, linalg.length(one_east - many_east) < 0.001)
	still, still_east := camera_spherical_pan_next(start, start_east, 0.3, {0, 1}, 60, 0)
	testing.expect_value(t, still, start)
	testing.expect_value(t, still_east, start_east)
}

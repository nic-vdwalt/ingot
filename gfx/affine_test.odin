#+build !js
// ingot:gfx - 2D model-transform tests.
//
// These fence the maths behind BeginMode2D and the rlgl matrix stack without a
// GPU: every batch primitive runs its vertices through _affine_apply, so
// getting the composition right here is what makes a Camera2D correct on
// screen. The rotation cases also pin the routing decision that sends a
// rotated rectangle down the four-corner path instead of the two-corner one.
package gfx

import "core:math"
import "core:testing"

@(private)
expect_point_near :: proc(t: ^testing.T, got, want: [2]f32, what: string) {
	testing.expectf(
		t,
		math.abs(got.x - want.x) < 1e-4 && math.abs(got.y - want.y) < 1e-4,
		"%s: got %v want %v",
		what,
		got,
		want,
	)
}

@(test)
affine_identity_is_a_no_op :: proc(t: ^testing.T) {
	expect_point_near(t, _affine_apply(AFFINE_IDENTITY, {3, -7}), {3, -7}, "identity")
	testing.expect(t, !_affine_rotates(AFFINE_IDENTITY))
}

@(test)
affine_translate_matches_the_offset_it_replaced :: proc(t: ^testing.T) {
	// The model transform generalises a plain [2]f32 offset. With an identity
	// linear part it must still behave exactly like adding that offset, or
	// every existing rlgl.Translatef consumer shifts.
	m := _affine_translated(AFFINE_IDENTITY, 10, 20)
	expect_point_near(t, _affine_apply(m, {0, 0}), {10, 20}, "origin")
	expect_point_near(t, _affine_apply(m, {5, 5}), {15, 25}, "offset point")

	stacked := _affine_translated(m, -4, 6)
	expect_point_near(t, _affine_apply(stacked, {0, 0}), {6, 26}, "composed translate")
}

@(test)
affine_translate_follows_camera_axes :: proc(t: ^testing.T) {
	// A model translate means "move along the current transform's axes", so
	// inside a zoomed camera it scales too. This is why translation composes
	// before the linear part rather than after.
	zoomed := Affine {
		a  = 2,
		b  = 0,
		c  = 0,
		d  = 2,
		tx = 0,
		ty = 0,
	}
	moved := _affine_translated(zoomed, 3, 4)
	expect_point_near(t, _affine_apply(moved, {0, 0}), {6, 8}, "translate scales with zoom")
}

@(test)
camera_2d_default_is_identity :: proc(t: ^testing.T) {
	camera := Camera2D {
		zoom = 1,
	}
	m := _affine_from_camera_2d(camera)
	expect_point_near(t, _affine_apply(m, {12, 34}), {12, 34}, "unit camera")
	testing.expect(t, !_affine_rotates(m))
}

@(test)
camera_2d_pins_target_to_offset :: proc(t: ^testing.T) {
	// The defining property of a Camera2D: the world point `target` lands at
	// the screen point `offset`, whatever the zoom or rotation.
	for rotation in ([]f32{0, 30, -90, 180}) {
		for zoom in ([]f32{0.5, 1, 3}) {
			camera := Camera2D {
				offset   = {400, 300},
				target   = {120, 80},
				rotation = rotation,
				zoom     = zoom,
			}
			m := _affine_from_camera_2d(camera)
			expect_point_near(t, _affine_apply(m, {120, 80}), {400, 300}, "target pins to offset")
		}
	}
}

@(test)
camera_2d_zoom_scales_about_the_target :: proc(t: ^testing.T) {
	camera := Camera2D {
		offset = {0, 0},
		target = {100, 100},
		zoom   = 2,
	}
	m := _affine_from_camera_2d(camera)
	expect_point_near(t, _affine_apply(m, {100, 100}), {0, 0}, "target")
	expect_point_near(t, _affine_apply(m, {110, 100}), {20, 0}, "10 world units at 2x")
	expect_point_near(t, _affine_apply(m, {100, 90}), {0, -20}, "negative offset scales too")
}

@(test)
camera_2d_rotation_is_reported_and_applied :: proc(t: ^testing.T) {
	camera := Camera2D {
		offset   = {0, 0},
		target   = {0, 0},
		rotation = 90,
		zoom     = 1,
	}
	m := _affine_from_camera_2d(camera)
	testing.expect(t, _affine_rotates(m), "a rotated camera must take the four-corner path")
	// +90 degrees maps the x axis onto the y axis.
	expect_point_near(t, _affine_apply(m, {1, 0}), {0, 1}, "x axis")
	expect_point_near(t, _affine_apply(m, {0, 1}), {-1, 0}, "y axis")
}

@(test)
camera_2d_rotation_preserves_lengths :: proc(t: ^testing.T) {
	camera := Camera2D {
		offset   = {50, 60},
		target   = {10, 20},
		rotation = 37,
		zoom     = 1,
	}
	m := _affine_from_camera_2d(camera)
	a := _affine_apply(m, {0, 0})
	b := _affine_apply(m, {30, 40}) // 3-4-5 triangle: length 50
	length := math.sqrt((b.x - a.x) * (b.x - a.x) + (b.y - a.y) * (b.y - a.y))
	testing.expectf(t, math.abs(length - 50) < 1e-3, "rotation should be rigid, got %v", length)
}

@(test)
camera_2d_axis_aligned_transforms_stay_axis_aligned :: proc(t: ^testing.T) {
	// Pan and zoom alone must keep the cheap two-corner rectangle path.
	camera := Camera2D {
		offset = {5, 5},
		target = {1, 2},
		zoom   = 4,
	}
	testing.expect(t, !_affine_rotates(_affine_from_camera_2d(camera)))
}

@(test)
camera_2d_round_trips_through_screen_space :: proc(t: ^testing.T) {
	camera := Camera2D {
		offset   = {320, 180},
		target   = {64, 96},
		rotation = 22.5,
		zoom     = 1.75,
	}
	for world in ([][2]f32{{0, 0}, {64, 96}, {-40, 130}, {900, -12}}) {
		point := Vector2{world.x, world.y}
		screen := GetWorldToScreen2D(point, camera)
		back := GetScreenToWorld2D(screen, camera)
		expect_point_near(t, {back.x, back.y}, world, "world->screen->world")
	}
}

@(test)
camera_2d_zero_zoom_is_bounded :: proc(t: ^testing.T) {
	// A zero-zoom camera collapses the world to a point, so the inverse does
	// not exist. raylib yields infinities; ingot returns the target instead of
	// letting NaNs reach layout or picking code.
	camera := Camera2D {
		offset = {10, 10},
		target = {7, 9},
		zoom   = 0,
	}
	back := GetScreenToWorld2D({100, 100}, camera)
	testing.expect_value(t, back, Vector2{7, 9})
}

@(test)
camera_2d_matrix_matches_the_affine :: proc(t: ^testing.T) {
	camera := Camera2D {
		offset   = {12, 34},
		target   = {56, 78},
		rotation = 45,
		zoom     = 2,
	}
	m := _affine_from_camera_2d(camera)
	matrix_form := GetCameraMatrix2D(camera)
	testing.expect_value(t, matrix_form[0, 0], m.a)
	testing.expect_value(t, matrix_form[1, 0], m.b)
	testing.expect_value(t, matrix_form[0, 1], m.c)
	testing.expect_value(t, matrix_form[1, 1], m.d)
	testing.expect_value(t, matrix_form[0, 3], m.tx)
	testing.expect_value(t, matrix_form[1, 3], m.ty)
	testing.expect_value(t, matrix_form[2, 2], f32(1))
	testing.expect_value(t, matrix_form[3, 3], f32(1))
}

@(test)
model_stack_holds_full_transforms :: proc(t: ^testing.T) {
	// The stack stores affines now, so pushing inside a camera and popping
	// restores the camera rather than dropping back to a bare offset.
	camera := Camera2D {
		offset = {0, 0},
		target = {0, 0},
		zoom   = 3,
	}
	saved := _affine_from_camera_2d(camera)
	nested := _affine_translated(saved, 10, 0)
	expect_point_near(t, _affine_apply(nested, {0, 0}), {30, 0}, "nested translate under zoom")
	expect_point_near(t, _affine_apply(saved, {0, 0}), {0, 0}, "saved transform is unchanged")
}

// --- emitted geometry ------------------------------------------------------
// The tests above fence the maths; these fence the routing, by driving the
// batch's _emit_* procedures against a private Renderer and reading back the
// vertices they produce. The _emit_* layer touches no shared frame state, so
// these stay deterministic under the concurrent test runner.
//
// A Renderer carries its vertex and index storage inline (fixed-capacity
// dynamic arrays), so it is megabytes wide and is heap-allocated here rather
// than declared on the stack.

@(private)
new_test_renderer :: proc() -> ^Renderer {
	r := new(Renderer)
	r.model_xf = AFFINE_IDENTITY
	return r
}

@(test)
emit_quad_keeps_rectangles_axis_aligned_without_rotation :: proc(t: ^testing.T) {
	r := new_test_renderer()
	defer free(r)

	r.model_xf = _affine_from_camera_2d(Camera2D{offset = {5, 7}, zoom = 2})
	_emit_quad(default_context(), r, {10, 20, 30, 40}, {0, 0, 1, 1}, {1, 1, 1, 1})

	testing.expect_value(t, len(r.verts), 4)
	testing.expect_value(t, len(r.indices), 6)
	// Emission order is tl, bl, tr, br; each corner is world*2 + offset.
	expect_point_near(t, r.verts[0].pos, {25, 47}, "tl")
	expect_point_near(t, r.verts[1].pos, {25, 127}, "bl")
	expect_point_near(t, r.verts[2].pos, {85, 47}, "tr")
	expect_point_near(t, r.verts[3].pos, {85, 127}, "br")
	// Axis alignment survives pan and zoom.
	testing.expect_value(t, r.verts[0].pos.x, r.verts[1].pos.x)
	testing.expect_value(t, r.verts[0].pos.y, r.verts[2].pos.y)
}

@(test)
emit_quad_rotates_all_four_corners :: proc(t: ^testing.T) {
	r := new_test_renderer()
	defer free(r)

	// A 90-degree camera about the origin. Under the translation-only offset
	// this generalises, the rectangle would have stayed axis-aligned.
	r.model_xf = _affine_from_camera_2d(Camera2D{rotation = 90, zoom = 1})
	testing.expect(t, _affine_rotates(r.model_xf))
	_emit_quad(default_context(), r, {10, 0, 20, 10}, {0, 0, 1, 1}, {1, 1, 1, 1})

	testing.expect_value(t, len(r.verts), 4)
	testing.expect_value(t, len(r.indices), 6)
	// +90 sends the x axis to the y axis, so the top edge becomes vertical.
	// The two-corner path cannot express this at all.
	expect_point_near(t, r.verts[0].pos, {0, 10}, "tl")
	expect_point_near(t, r.verts[2].pos, {0, 30}, "tr")
	expect_point_near(t, r.verts[1].pos, {-10, 10}, "bl")
	expect_point_near(t, r.verts[3].pos, {-10, 30}, "br")
	// The top edge is vertical: its corners share an x within the rounding of
	// cos(90 degrees), which is not exactly zero in f32.
	testing.expect(t, math.abs(r.verts[0].pos.x - r.verts[2].pos.x) < 1e-4)
}

@(test)
emit_quad_preserves_uv_and_mode_through_the_rotated_path :: proc(t: ^testing.T) {
	// Text draws as textured quads in .Text mode. Routing a rotated glyph
	// through the four-corner path must not drop its atlas uv or its mode,
	// which would render it as an opaque solid block.
	r := new_test_renderer()
	defer free(r)

	r.model_xf = _affine_from_camera_2d(Camera2D{rotation = 45, zoom = 1})
	_emit_quad(default_context(), r, {0, 0, 8, 8}, {0.25, 0.5, 0.125, 0.25}, {1, 1, 1, 1}, .Text)

	testing.expect_value(t, len(r.verts), 4)
	for vertex in r.verts do testing.expect_value(t, vertex.mode, Vertex_Mode.Text)
	expect_point_near(t, r.verts[0].uv, {0.25, 0.5}, "uv tl")
	expect_point_near(t, r.verts[1].uv, {0.25, 0.75}, "uv bl")
	expect_point_near(t, r.verts[2].uv, {0.375, 0.5}, "uv tr")
	expect_point_near(t, r.verts[3].uv, {0.375, 0.75}, "uv br")
}

@(test)
emit_quad_matches_the_unrotated_path_when_transform_is_identity :: proc(t: ^testing.T) {
	// The two paths must agree wherever both are valid, or enabling a camera
	// would shift geometry by itself.
	direct := new_test_renderer()
	defer free(direct)
	general := new_test_renderer()
	defer free(general)

	_emit_quad(direct, {3, 5, 7, 11}, {0, 0, 1, 1}, {1, 1, 1, 1})
	_emit_quad4(
		default_context(),
		general,
		{3, 5},
		{10, 5},
		{10, 16},
		{3, 16},
		{0, 0},
		{1, 0},
		{1, 1},
		{0, 1},
		{1, 1, 1, 1},
	)

	testing.expect_value(t, len(direct.verts), len(general.verts))
	for vertex, index in direct.verts {
		expect_point_near(t, vertex.pos, general.verts[index].pos, "corner")
		expect_point_near(t, vertex.uv, general.verts[index].uv, "uv")
	}
	testing.expect_value(t, len(direct.indices), len(general.indices))
	for value, index in direct.indices {
		testing.expect_value(t, value, general.indices[index])
	}
}

@(test)
emit_tri_follows_the_model_transform :: proc(t: ^testing.T) {
	r := new_test_renderer()
	defer free(r)

	r.model_xf = _affine_translated(AFFINE_IDENTITY, 100, 200)
	_emit_tri(default_context(), r, {0, 0}, {10, 0}, {0, 10}, {1, 1, 1, 1})

	testing.expect_value(t, len(r.verts), 3)
	expect_point_near(t, r.verts[0].pos, {100, 200}, "a")
	expect_point_near(t, r.verts[1].pos, {110, 200}, "b")
	expect_point_near(t, r.verts[2].pos, {100, 210}, "c")
}

@(test)
emit_gradient_quad_follows_the_model_transform :: proc(t: ^testing.T) {
	// Gradients used to append vertices directly and so ignored the model
	// transform entirely: they stayed pinned to the screen while everything
	// else moved with the camera.
	r := new_test_renderer()
	defer free(r)

	r.model_xf = _affine_from_camera_2d(Camera2D{offset = {0, 0}, target = {0, 0}, zoom = 2})
	top := [4]f32{1, 0, 0, 1}
	bottom := [4]f32{0, 0, 1, 1}
	_emit_gradient_quad(default_context(), r, {1, 2, 3, 4}, top, top, bottom, bottom)

	testing.expect_value(t, len(r.verts), 4)
	expect_point_near(t, r.verts[0].pos, {2, 4}, "tl scales with zoom")
	expect_point_near(t, r.verts[3].pos, {8, 12}, "br scales with zoom")
	// Emission order is tl, bl, tr, br, so the vertical ramp must land on
	// vertices 1 and 3.
	testing.expect_value(t, r.verts[0].col, top)
	testing.expect_value(t, r.verts[1].col, bottom)
	testing.expect_value(t, r.verts[2].col, top)
	testing.expect_value(t, r.verts[3].col, bottom)
}

// --- finiteness contracts --------------------------------------------------
// A non-finite transform maps every vertex to NaN: the GPU discards the
// primitives and the frame is blank with nothing logged. Application code
// reaches this easily (a zoom animation dividing by zero, normalising a
// zero-length vector), so the constructors assert rather than emit it.
//
// The asserts themselves cannot be exercised from a test without aborting the
// runner, so these fence the predicate that backs them and the boundary
// between "degenerate but well defined" and "corrupt".

@(test)
f32_finite_predicate_rejects_inf_and_nan :: proc(t: ^testing.T) {
	testing.expect(t, _f32_is_finite(0))
	testing.expect(t, _f32_is_finite(-1))
	testing.expect(t, _f32_is_finite(max(f32)))
	testing.expect(t, _f32_is_finite(min(f32)))
	testing.expect(t, !_f32_is_finite(math.inf_f32(1)))
	testing.expect(t, !_f32_is_finite(math.inf_f32(-1)))
	testing.expect(t, !_f32_is_finite(math.nan_f32()))
}

@(test)
affine_finite_predicate_checks_every_component :: proc(t: ^testing.T) {
	testing.expect(t, _affine_is_finite(AFFINE_IDENTITY))
	// Each of the six components must be covered; a predicate that forgot one
	// would still pass a whole-struct smoke test.
	nan := math.nan_f32()
	for index in 0 ..< 6 {
		poisoned := AFFINE_IDENTITY
		switch index {
		case 0:
			poisoned.a = nan
		case 1:
			poisoned.b = nan
		case 2:
			poisoned.c = nan
		case 3:
			poisoned.d = nan
		case 4:
			poisoned.tx = nan
		case 5:
			poisoned.ty = nan
		}
		testing.expectf(t, !_affine_is_finite(poisoned), "component %v not checked", index)
	}
}

@(test)
zero_zoom_camera_is_finite_and_allowed :: proc(t: ^testing.T) {
	// Degenerate but well defined: the world collapses to a point. This must
	// stay legal, because a zoom animation can pass through zero and
	// GetScreenToWorld2D already handles the missing inverse.
	m := _affine_from_camera_2d(Camera2D{offset = {10, 20}, target = {3, 4}, zoom = 0})
	testing.expect(t, _affine_is_finite(m))
	testing.expect_value(t, _affine_apply(m, {1e6, -1e6}), [2]f32{10, 20})
}

@(test)
extreme_but_finite_camera_stays_finite :: proc(t: ^testing.T) {
	// The boundary the assert must not false-positive on: values large enough
	// to look alarming, small enough to stay in range.
	m := _affine_from_camera_2d(
		Camera2D{offset = {1e6, -1e6}, target = {1e6, 1e6}, rotation = 720, zoom = 1e3},
	)
	testing.expect(t, _affine_is_finite(m))
}

@(test)
nan_camera_would_poison_every_vertex :: proc(t: ^testing.T) {
	// Why the assert exists. Built by hand rather than through the guarded
	// constructor, this is what used to reach the batch: finite input
	// geometry, NaN output, no error anywhere.
	poisoned := Affine {
		a  = math.nan_f32(),
		b  = 0,
		c  = 0,
		d  = math.nan_f32(),
		tx = 0,
		ty = 0,
	}
	testing.expect(t, !_affine_is_finite(poisoned))

	r := new_test_renderer()
	defer free(r)
	r.model_xf = poisoned
	_emit_quad(default_context(), r, {10, 20, 30, 40}, {0, 0, 1, 1}, {1, 1, 1, 1})

	testing.expect_value(t, len(r.verts), 4)
	for vertex, index in r.verts {
		testing.expectf(
			t,
			vertex.pos.x != vertex.pos.x,
			"vertex %v should be NaN without the guard, got %v",
			index,
			vertex.pos,
		)
	}
}

@(test)
composed_transforms_stay_finite :: proc(t: ^testing.T) {
	camera := _affine_from_camera_2d(Camera2D{zoom = 2, rotation = 30})
	pivot := _affine_from_camera_2d(Camera2D{offset = {5, 5}, target = {5, 5}, rotation = -30})
	testing.expect(t, _affine_is_finite(_affine_compose(camera, pivot)))
	testing.expect(t, _affine_is_finite(_affine_translated(camera, 1e4, -1e4)))
}

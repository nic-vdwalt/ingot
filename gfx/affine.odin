// ingot:gfx - the 2D model transform applied to batch geometry.
//
// Two public surfaces feed it: rlgl's matrix stack (PushMatrix / Translatef /
// PopMatrix) and raylib's Camera2D (BeginMode2D / EndMode2D). Both need more
// than the plain translation offset this replaced, because a Camera2D also
// zooms and rotates, so the batch carries a 2x3 affine and applies it to every
// vertex it emits.
//
// Only 2D affines are represented. Anything needing perspective, depth, or a
// full 4x4 belongs in the explicit GPU 3D path (gpu3d.odin), not here.
//
// Two procedures here are `contextless` and two are not, deliberately.
// _affine_apply and _affine_rotates run once per vertex and per quad, so they
// stay contextless (Odin's `assert` needs a context, and this is the batch's
// inner loop). The constructors below run once per camera change, matrix
// translate, or rotated text draw, so they carry the finiteness contracts for
// the whole pipeline: a transform is validated where external floats enter it,
// not re-checked per vertex.
package gfx

import "core:math"

// Affine maps a point p to:
//
//	x' = a*x + c*y + tx
//	y' = b*x + d*y + ty
//
// Column-major naming follows the usual 2x3 convention: (a, b) is the image of
// the x axis, (c, d) the image of the y axis, and (tx, ty) the translation.
Affine :: struct {
	a, b, c, d: f32,
	tx, ty:     f32,
}

AFFINE_IDENTITY :: Affine {
	a  = 1,
	b  = 0,
	c  = 0,
	d  = 1,
	tx = 0,
	ty = 0,
}

// _f32_is_finite rejects both infinities and NaN in one comparison: every
// ordered comparison against NaN is false, and an infinity exceeds max(f32).
@(private)
_f32_is_finite :: proc "contextless" (value: f32) -> bool {
	return abs(value) <= max(f32)
}

// _affine_is_finite reports whether a transform can produce usable geometry.
//
// A non-finite transform is not a rendering edge case, it is a silent one: it
// maps every vertex to NaN, the GPU discards the primitives, and the frame
// comes out blank with nothing logged. Application code reaches it easily -
// a zoom animation dividing by zero, or normalising a zero-length vector - so
// the pipeline asserts on it rather than drawing nothing.
@(private)
_affine_is_finite :: proc "contextless" (m: Affine) -> bool {
	return(
		_f32_is_finite(m.a) &&
		_f32_is_finite(m.b) &&
		_f32_is_finite(m.c) &&
		_f32_is_finite(m.d) &&
		_f32_is_finite(m.tx) &&
		_f32_is_finite(m.ty) \
	)
}

// _affine_apply transforms a point.
//
// Contextless and assertion-free by design: this is the per-vertex hot path.
// Its precondition (a finite `m`) is established by the constructors below and
// asserted there, once per transform change instead of once per vertex.
@(private)
_affine_apply :: proc "contextless" (m: Affine, p: [2]f32) -> [2]f32 {
	return {m.a * p.x + m.c * p.y + m.tx, m.b * p.x + m.d * p.y + m.ty}
}

// _affine_rotates reports whether the linear part mixes the axes, which is the
// case exactly when an axis-aligned rectangle does not stay axis-aligned. The
// batch uses this to decide between the two-corner rectangle path and the
// four-corner quad path. Per-quad, so contextless for the same reason.
@(private)
_affine_rotates :: proc "contextless" (m: Affine) -> bool {
	return m.b != 0 || m.c != 0
}

// _affine_translated composes `m` with a translation applied *before* it, which
// is what a model-matrix translate means: rlgl.Translatef inside a rotated or
// zoomed camera moves along the camera's axes, not the screen's.
//
// With an identity linear part this reduces to adding the offset, preserving
// the behaviour of the translation-only stack this generalises.
@(private)
_affine_translated :: proc(m: Affine, x, y: f32) -> Affine {
	assert(_affine_is_finite(m), "_affine_translated: non-finite source transform")
	assert(_f32_is_finite(x), "_affine_translated: non-finite x")
	assert(_f32_is_finite(y), "_affine_translated: non-finite y")
	result := m
	result.tx = m.a * x + m.c * y + m.tx
	result.ty = m.b * x + m.d * y + m.ty
	assert(_affine_is_finite(result), "_affine_translated: produced a non-finite transform")
	return result
}

// _affine_compose returns the transform that applies `inner` first and `outer`
// second, so composing a rotation onto an active camera keeps the camera.
@(private)
_affine_compose :: proc(outer, inner: Affine) -> Affine {
	assert(_affine_is_finite(outer), "_affine_compose: non-finite outer transform")
	assert(_affine_is_finite(inner), "_affine_compose: non-finite inner transform")
	result := Affine {
		a  = outer.a * inner.a + outer.c * inner.b,
		b  = outer.b * inner.a + outer.d * inner.b,
		c  = outer.a * inner.c + outer.c * inner.d,
		d  = outer.b * inner.c + outer.d * inner.d,
		tx = outer.a * inner.tx + outer.c * inner.ty + outer.tx,
		ty = outer.b * inner.tx + outer.d * inner.ty + outer.ty,
	}
	// Two finite transforms can still overflow to infinity when composed, so
	// this is a real check rather than a restatement of the preconditions.
	assert(_affine_is_finite(result), "_affine_compose: produced a non-finite transform")
	return result
}

// _affine_from_camera_2d builds raylib's Camera2D transform:
//
//	p' = rotate(zoom * (p - target)) + offset
//
// so `target` names the world point pinned to `offset` in screen space, zoom
// scales about it, and rotation is in degrees about it.
//
// A zero zoom is allowed: it collapses the world to a point, which is finite
// and renders nothing visible. That is degenerate but well defined, unlike a
// non-finite camera, and GetScreenToWorld2D handles its missing inverse.
@(private)
_affine_from_camera_2d :: proc(camera: Camera2D) -> Affine {
	assert(_f32_is_finite(camera.zoom), "_affine_from_camera_2d: non-finite zoom")
	assert(_f32_is_finite(camera.rotation), "_affine_from_camera_2d: non-finite rotation")
	assert(_f32_is_finite(camera.offset.x), "_affine_from_camera_2d: non-finite offset x")
	assert(_f32_is_finite(camera.offset.y), "_affine_from_camera_2d: non-finite offset y")
	assert(_f32_is_finite(camera.target.x), "_affine_from_camera_2d: non-finite target x")
	assert(_f32_is_finite(camera.target.y), "_affine_from_camera_2d: non-finite target y")

	radians := camera.rotation * math.PI / 180.0
	cos_r := math.cos(radians)
	sin_r := math.sin(radians)
	result := Affine {
		a = cos_r * camera.zoom,
		b = sin_r * camera.zoom,
		c = -sin_r * camera.zoom,
		d = cos_r * camera.zoom,
	}
	result.tx = camera.offset.x - (result.a * camera.target.x + result.c * camera.target.y)
	result.ty = camera.offset.y - (result.b * camera.target.x + result.d * camera.target.y)

	// A finite camera can still overflow: a large zoom times a large target
	// exceeds f32 range, and infinity times a zero target is NaN. Every vertex
	// this frame flows through the result, so it is checked before install.
	assert(_affine_is_finite(result), "_affine_from_camera_2d: produced a non-finite transform")
	return result
}

// ingot:gfx — the 2D model transform applied to batch geometry.
//
// Two public surfaces feed it: rlgl's matrix stack (PushMatrix / Translatef /
// PopMatrix) and raylib's Camera2D (BeginMode2D / EndMode2D). Both need more
// than the plain translation offset this replaced, because a Camera2D also
// zooms and rotates, so the batch carries a 2x3 affine and applies it to every
// vertex it emits.
//
// Only 2D affines are represented. Anything needing perspective, depth, or a
// full 4x4 belongs in the explicit GPU 3D path (gpu3d.odin), not here.
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

// _affine_apply transforms a point.
@(private)
_affine_apply :: proc "contextless" (m: Affine, p: [2]f32) -> [2]f32 {
	return {m.a * p.x + m.c * p.y + m.tx, m.b * p.x + m.d * p.y + m.ty}
}

// _affine_rotates reports whether the linear part mixes the axes, which is the
// case exactly when an axis-aligned rectangle does not stay axis-aligned. The
// batch uses this to decide between the two-corner rectangle path and the
// four-corner quad path.
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
_affine_translated :: proc "contextless" (m: Affine, x, y: f32) -> Affine {
	result := m
	result.tx = m.a * x + m.c * y + m.tx
	result.ty = m.b * x + m.d * y + m.ty
	return result
}

// _affine_compose returns the transform that applies `inner` first and `outer`
// second, so composing a rotation onto an active camera keeps the camera.
@(private)
_affine_compose :: proc "contextless" (outer, inner: Affine) -> Affine {
	return Affine {
		a = outer.a * inner.a + outer.c * inner.b,
		b = outer.b * inner.a + outer.d * inner.b,
		c = outer.a * inner.c + outer.c * inner.d,
		d = outer.b * inner.c + outer.d * inner.d,
		tx = outer.a * inner.tx + outer.c * inner.ty + outer.tx,
		ty = outer.b * inner.tx + outer.d * inner.ty + outer.ty,
	}
}

// _affine_from_camera_2d builds raylib's Camera2D transform:
//
//	p' = rotate(zoom * (p - target)) + offset
//
// so `target` names the world point pinned to `offset` in screen space, zoom
// scales about it, and rotation is in degrees about it.
@(private)
_affine_from_camera_2d :: proc "contextless" (camera: Camera2D) -> Affine {
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
	return result
}

// ingot:gfx — raymath helpers (subset apps reference). Names/semantics match
// raylib's raymath so call sites port unchanged.
package gfx

import "core:math"

Vector2Distance :: proc(v1, v2: Vector2) -> f32 {
	dx := v2.x - v1.x
	dy := v2.y - v1.y
	return math.sqrt(dx * dx + dy * dy)
}

// Squared distance (raylib spells this Vector2DistanceSqr; some call sites use
// the "Sqrt" spelling — both provided, both return the squared distance).
Vector2DistanceSqr :: proc(v1, v2: Vector2) -> f32 {
	dx := v2.x - v1.x
	dy := v2.y - v1.y
	return dx * dx + dy * dy
}
Vector2DistanceSqrt :: Vector2DistanceSqr

Vector2Add :: proc(v1, v2: Vector2) -> Vector2 { return {v1.x + v2.x, v1.y + v2.y} }
Vector2Subtract :: proc(v1, v2: Vector2) -> Vector2 { return {v1.x - v2.x, v1.y - v2.y} }
Vector2Scale :: proc(v: Vector2, s: f32) -> Vector2 { return {v.x * s, v.y * s} }
Vector2Length :: proc(v: Vector2) -> f32 { return math.sqrt(v.x * v.x + v.y * v.y) }

Vector2Lerp :: proc(v1, v2: Vector2, amount: f32) -> Vector2 {
	return {v1.x + amount * (v2.x - v1.x), v1.y + amount * (v2.y - v1.y)}
}

Lerp :: proc(start, end, amount: f32) -> f32 { return start + amount * (end - start) }

// ingot:gfx - optional orbit-camera input bindings.
//
// camera.odin is deliberately pure: update_orbit_camera consumes a semantic
// Orbit_Camera_Input and never asks the platform anything, which is what lets
// it be driven from a replay, a network stream, or a headless test. This file
// is the one place that couples the orbit camera to the default input context,
// and it is opt-in: an application that wants different bindings, gated input,
// or a non-keyboard source keeps building Orbit_Camera_Input itself and never
// imports this behaviour by accident.
package gfx

// orbit_camera_bindings_default returns the conventional arrow/WASD scheme:
// left and right orbit, up and down dolly, left-drag orbits, wheel dollies.
// The drag scale is negative on both axes so the world tracks the cursor -
// dragging left spins the camera right, which is what "grabbing" the scene
// feels like. A zero scale disables pointer drag.
orbit_camera_bindings_default :: proc() -> Orbit_Camera_Bindings {
	return {
		rotate_left = {primary = .LEFT, secondary = .A},
		rotate_right = {primary = .RIGHT, secondary = .D},
		zoom_in = {primary = .UP, secondary = .W},
		zoom_out = {primary = .DOWN, secondary = .S},
		drag_button = .LEFT,
		pointer_drag_scale = {-1, -1},
	}
}

// orbit_camera_input_poll samples the default input context into the semantic
// input update_orbit_camera consumes. Rates are unitless and accumulate so an
// application can add its own contribution to the result before stepping.
orbit_camera_input_poll :: proc(bindings: Orbit_Camera_Bindings) -> Orbit_Camera_Input {
	assert(
		_f32_is_finite(bindings.pointer_drag_scale.x),
		"orbit_camera_input_poll: invalid drag scale",
	)
	assert(
		_f32_is_finite(bindings.pointer_drag_scale.y),
		"orbit_camera_input_poll: invalid drag scale",
	)
	input: Orbit_Camera_Input
	if _orbit_key_pair_down(bindings.rotate_left) do input.rotate_rate.x += 1
	if _orbit_key_pair_down(bindings.rotate_right) do input.rotate_rate.x -= 1
	if _orbit_key_pair_down(bindings.zoom_in) do input.zoom_rate -= 1
	if _orbit_key_pair_down(bindings.zoom_out) do input.zoom_rate += 1
	if IsMouseButtonDown(bindings.drag_button) {
		input.pointer_drag = GetMouseDelta() * bindings.pointer_drag_scale
	}
	input.scroll = GetMouseWheelMoveV().y
	// update_orbit_camera asserts on non-finite input, so a hostile or
	// glitched pointer delta must be caught here rather than crash the camera
	// step with a message that points at the wrong subsystem.
	if !_f32_is_finite(input.pointer_drag.x) do input.pointer_drag.x = 0
	if !_f32_is_finite(input.pointer_drag.y) do input.pointer_drag.y = 0
	if !_f32_is_finite(input.scroll) do input.scroll = 0
	return input
}

// _orbit_key_pair_down short-circuits KEY_NULL so an unbound axis never reaches
// the platform layer, which has no window in a headless process.
@(private)
_orbit_key_pair_down :: proc(pair: Orbit_Camera_Key_Pair) -> bool {
	assert(i32(pair.primary) >= 0, "_orbit_key_pair_down: negative key")
	assert(i32(pair.secondary) >= 0, "_orbit_key_pair_down: negative key")
	if pair.primary != .KEY_NULL && IsKeyDown(pair.primary) do return true
	if pair.secondary != .KEY_NULL && IsKeyDown(pair.secondary) do return true
	return false
}

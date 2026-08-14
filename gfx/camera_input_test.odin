// Bindings polling tests. The unguarded cases cover the parts that need no
// platform at all - the default scheme's shape and the unbound-key negative
// space. The guarded cases drive gfx/input_sim.odin, so they only compile
// under -define:INGOT_INPUT_SIM=true, which is how the gate runs this package.
#+build !js
package gfx

import "core:testing"

@(test)
orbit_camera_bindings_default_is_accepted_by_the_camera :: proc(t: ^testing.T) {
	bindings := orbit_camera_bindings_default()
	testing.expect_value(t, bindings.rotate_left.primary, KeyboardKey.LEFT)
	testing.expect_value(t, bindings.rotate_left.secondary, KeyboardKey.A)
	testing.expect_value(t, bindings.drag_button, MouseButton.LEFT)
	// Drag must invert on both axes or the scene fights the cursor.
	testing.expect_value(t, bindings.pointer_drag_scale, Vector2{-1, -1})
}

// An entirely unbound scheme must never touch the platform layer, which is the
// property that lets a headless process poll safely.
@(test)
orbit_camera_input_poll_ignores_unbound_keys :: proc(t: ^testing.T) {
	testing.expect(t, !_orbit_key_pair_down({}))
	testing.expect(t, !_orbit_key_pair_down({primary = .KEY_NULL, secondary = .KEY_NULL}))
}

when INGOT_INPUT_SIM {
	@(private = "file")
	sim_lock :: proc() {
		gfx_shared_test_lock()
		SimReset()
	}

	@(private = "file")
	sim_unlock :: proc() {
		SimReset()
		gfx_shared_test_unlock()
	}

	@(test)
	orbit_camera_input_poll_maps_keys_to_rates :: proc(t: ^testing.T) {
		sim_lock()
		defer sim_unlock()
		bindings := orbit_camera_bindings_default()

		SimBeginFrame()
		SimKey(.A, true)
		SimKey(.S, true)
		left := orbit_camera_input_poll(bindings)
		testing.expect_value(t, left.rotate_rate.x, f32(1))
		testing.expect_value(t, left.zoom_rate, f32(1))

		SimBeginFrame()
		SimKey(.A, false)
		SimKey(.S, false)
		SimKey(.RIGHT, true)
		SimKey(.UP, true)
		right := orbit_camera_input_poll(bindings)
		testing.expect_value(t, right.rotate_rate.x, f32(-1))
		testing.expect_value(t, right.zoom_rate, f32(-1))
	}

	// Opposed keys must cancel rather than latch to whichever was tested last.
	@(test)
	orbit_camera_input_poll_cancels_opposed_keys :: proc(t: ^testing.T) {
		sim_lock()
		defer sim_unlock()
		SimBeginFrame()
		SimKey(.A, true)
		SimKey(.D, true)
		SimKey(.W, true)
		SimKey(.S, true)
		input := orbit_camera_input_poll(orbit_camera_bindings_default())
		testing.expect_value(t, input.rotate_rate.x, f32(0))
		testing.expect_value(t, input.zoom_rate, f32(0))
	}

	@(test)
	orbit_camera_input_poll_reads_drag_only_while_held :: proc(t: ^testing.T) {
		sim_lock()
		defer sim_unlock()
		bindings := orbit_camera_bindings_default()

		SimBeginFrame()
		SimMouse(10, 20)
		SimBeginFrame()
		SimMouse(14, 26)
		released := orbit_camera_input_poll(bindings)
		testing.expect_value(t, released.pointer_drag, Vector2{0, 0})

		SimBeginFrame()
		SimButton(.LEFT, true)
		SimMouse(18, 32)
		held := orbit_camera_input_poll(bindings)
		// Scale is {-1, -1}, so a +4/+6 cursor move drags -4/-6.
		testing.expect_value(t, held.pointer_drag, Vector2{-4, -6})
	}

	@(test)
	orbit_camera_pointer_intent_gates_rotate_behind_modifier :: proc(t: ^testing.T) {
		sim_lock()
		defer sim_unlock()
		bindings := orbit_camera_bindings_default()
		bindings.drag_modifier = {
			primary = .LEFT_ALT,
		}
		bindings.pan_button = {
			button = .LEFT,
			bound  = true,
		}

		SimBeginFrame()
		SimButton(.LEFT, true)
		testing.expect_value(
			t,
			orbit_camera_pointer_intent(bindings),
			Orbit_Camera_Pointer_Intent.Pan,
		)
		// A modifier-less drag must not leak into the rotation channel.
		testing.expect_value(t, orbit_camera_input_poll(bindings).pointer_drag, Vector2{0, 0})

		SimBeginFrame()
		SimKey(.LEFT_ALT, true)
		testing.expect_value(
			t,
			orbit_camera_pointer_intent(bindings),
			Orbit_Camera_Pointer_Intent.Rotate,
		)
	}

	@(test)
	orbit_camera_input_poll_takes_vertical_wheel :: proc(t: ^testing.T) {
		sim_lock()
		defer sim_unlock()
		SimBeginFrame()
		SimWheel(3, -2)
		input := orbit_camera_input_poll(orbit_camera_bindings_default())
		// Horizontal wheel is not a dolly; only the vertical axis is read.
		testing.expect_value(t, input.scroll, f32(-2))
	}

	// The polled input must satisfy update_orbit_camera's preconditions, which
	// is the whole point of the two living in the same package.
	@(test)
	orbit_camera_input_poll_feeds_the_camera_step :: proc(t: ^testing.T) {
		sim_lock()
		defer sim_unlock()
		SimBeginFrame()
		SimKey(.A, true)
		SimWheel(0, 1)
		state := Orbit_Camera_State {
			target   = {0, 0, 0},
			yaw      = 0,
			pitch    = 0.2,
			distance = 10,
		}
		config := orbit_camera_config_default()
		input := orbit_camera_input_poll(orbit_camera_bindings_default())
		update_orbit_camera(&state, input, config, 1.0 / 60.0)
		testing.expect(t, state.yaw > 0, "left key must increase yaw")
		testing.expect(t, state.distance < 10, "positive scroll must dolly in")
	}
}

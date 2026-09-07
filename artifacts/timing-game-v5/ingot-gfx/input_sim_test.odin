#+build !js
package gfx

import "core:testing"

_ :: testing

when INGOT_INPUT_SIM {
	@(test)
	input_sim_isolated_between_contexts :: proc(t: ^testing.T) {
		first := new(Context)
		second := new(Context)
		defer free(first)
		defer free(second)

		context_sim_key(first, .A, true)
		context_sim_button(first, .LEFT, true)
		context_sim_mouse(first, 12, 18)
		context_sim_char(first, 'a')
		context_sim_wheel(first, 2, -3)
		_ = context_sim_pointer(
			first,
			{
				id = 9,
				position = {12, 18},
				pressure = 1,
				buttons = 1,
				kind = .Down,
				pointer_type = .Touch,
				button = .Left,
				primary = true,
			},
		)

		testing.expect(t, context_is_key_pressed(first, .A))
		testing.expect(t, context_is_key_down(first, .A))
		testing.expect(t, !context_is_key_pressed(second, .A))
		testing.expect(t, !context_is_key_down(second, .A))
		testing.expect(t, context_is_mouse_button_pressed(first, .LEFT))
		testing.expect(t, context_is_mouse_button_down(first, .LEFT))
		testing.expect(t, !context_is_mouse_button_pressed(second, .LEFT))
		testing.expect(t, !context_is_mouse_button_down(second, .LEFT))
		testing.expect_value(t, first.inp.mouse, Vector2{12, 18})
		testing.expect_value(t, second.inp.mouse, Vector2{})
		testing.expect_value(t, context_get_char_pressed_impl(first), rune('a'))
		testing.expect_value(t, context_get_char_pressed_impl(second), rune(0))
		testing.expect_value(t, first.inp.wheel, Vector2{2, -3})
		testing.expect_value(t, second.inp.wheel, Vector2{})
		testing.expect_value(t, len(context_pointer_events(first)), 1)
		testing.expect_value(t, len(context_pointer_events(second)), 0)

		context_sim_begin_frame(first)
		testing.expect_value(t, len(context_pointer_events(first)), 0)
		testing.expect(t, !context_is_key_pressed(first, .A))
		testing.expect(t, context_is_key_down(first, .A))
		testing.expect(t, !context_is_mouse_button_pressed(first, .LEFT))
		testing.expect(t, context_is_mouse_button_down(first, .LEFT))

		context_sim_key(first, .A, false)
		context_sim_button(first, .LEFT, false)
		testing.expect(t, context_is_key_released(first, .A))
		testing.expect(t, !context_is_key_down(first, .A))
		testing.expect(t, context_is_mouse_button_released(first, .LEFT))
		testing.expect(t, !context_is_mouse_button_down(first, .LEFT))
	}

	@(test)
	input_sim_reset_is_context_local :: proc(t: ^testing.T) {
		first := new(Context)
		second := new(Context)
		defer free(first)
		defer free(second)

		context_sim_key(first, .A, true)
		context_sim_key(second, .B, true)
		context_sim_char(second, 'b')
		context_sim_reset(first)

		testing.expect(t, !context_is_key_down(first, .A))
		testing.expect(t, context_is_key_down(second, .B))
		testing.expect_value(t, context_get_char_pressed_impl(second), rune('b'))
	}
}

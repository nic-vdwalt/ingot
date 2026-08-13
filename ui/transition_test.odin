#+build !js
package ui

import "core:math"
import "core:testing"

@(test)
transition_first_use_snaps_and_reset_animates :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	input := Ui_Input {
		frame_time = 1.0 / 60.0,
	}
	output := new(Ui_Output)
	defer free(output)
	frame := Ui_Frame {
		output = output,
	}
	ui_frame_begin(&frame, &runtime, &input)
	defer ui_frame_end(&frame)

	state: Transition_F32_State
	testing.expect_value(t, transition_f32(&frame, &state, 20), f32(20))
	testing.expect(t, transition_f32_settled(&state))
	transition_f32_reset(&state, 0)
	value := transition_f32(&frame, &state, 20)
	testing.expect(t, value > 0 && value < 20)
	testing.expect(t, output.platform.request_redraw)
}

@(test)
transition_values_converge_and_stop_redrawing :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	input := Ui_Input {
		frame_time = 1.0 / 60.0,
	}
	frame: Ui_Frame
	f32_state: Transition_F32_State
	color_state: Transition_Color_State
	rect_state: Transition_Rect_State
	transition_f32_reset(&f32_state, 0)
	transition_color_reset(&color_state, {0, 10, 20, 30})
	transition_rect_reset(&rect_state, {0, 0, 10, 20})

	for _ in 0 ..< 1_000 {
		ui_frame_begin(&frame, &runtime, &input)
		_ = transition_f32(&frame, &f32_state, 1)
		_ = transition_color(&frame, &color_state, {100, 110, 120, 130})
		_ = transition_rect(&frame, &rect_state, {30, 40, 50, 60})
		ui_frame_end(&frame)
		if transition_f32_settled(&f32_state) &&
		   transition_color_settled(&color_state) &&
		   transition_rect_settled(&rect_state) {
			break
		}
	}
	testing.expect_value(t, f32_state.current, f32(1))
	testing.expect_value(t, color_state.current, Color{100, 110, 120, 130})
	testing.expect_value(t, rect_state.current, Rect_I32{30, 40, 50, 60})
}

@(test)
transition_reduced_motion_snaps_without_redraw :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	theme := theme_dark()
	theme.reduced_motion = true
	ui_runtime_set_theme(&runtime, theme)
	input := Ui_Input {
		frame_time = 1.0 / 60.0,
	}
	output := new(Ui_Output)
	defer free(output)
	frame := Ui_Frame {
		output = output,
	}
	ui_frame_begin(&frame, &runtime, &input)
	defer ui_frame_end(&frame)

	state: Transition_Rect_State
	transition_rect_reset(&state, {0, 0, 10, 10})
	value := transition_rect(&frame, &state, {100, 200, 30, 40})
	testing.expect_value(t, value, Rect_I32{100, 200, 30, 40})
	testing.expect(t, transition_rect_settled(&state))
	testing.expect(t, !output.platform.request_redraw)
}

@(test)
transition_huge_and_nan_delta_remain_safe :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	state: Transition_F32_State
	transition_f32_reset(&state, 0)
	input := Ui_Input {
		frame_time = 1e30,
	}
	frame: Ui_Frame
	ui_frame_begin(&frame, &runtime, &input)
	testing.expect_value(t, transition_f32(&frame, &state, 10), f32(10))
	ui_frame_end(&frame)

	transition_f32_reset(&state, 2)
	input.frame_time = math.nan_f32()
	ui_frame_begin(&frame, &runtime, &input)
	testing.expect_value(t, transition_f32(&frame, &state, 10), f32(2))
	ui_frame_end(&frame)
}

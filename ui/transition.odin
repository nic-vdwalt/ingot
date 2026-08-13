package ui

import "core:math"

TRANSITION_SPEED_DEFAULT :: 10.0
TRANSITION_SETTLE_EPSILON :: 0.001

Transition_Options :: struct {
	speed: f32,
}

Transition_F32_State :: struct {
	current:     f32,
	target:      f32,
	initialized: bool,
}

Transition_Color_State :: struct {
	current:     Color,
	target:      Color,
	initialized: bool,
}

Transition_Rect_State :: struct {
	current:     Rect_I32,
	target:      Rect_I32,
	initialized: bool,
}

transition_f32_reset :: proc(state: ^Transition_F32_State, value: f32) {
	assert(state != nil, "transition_f32_reset: nil state")
	assert(transition_value_finite(value), "transition_f32_reset: non-finite value")
	state^ = {
		current     = value,
		target      = value,
		initialized = true,
	}
	assert(transition_f32_settled(state), "transition_f32_reset: state not settled")
}

transition_color_reset :: proc(state: ^Transition_Color_State, value: Color) {
	assert(state != nil, "transition_color_reset: nil state")
	state^ = {
		current     = value,
		target      = value,
		initialized = true,
	}
	assert(transition_color_settled(state), "transition_color_reset: state not settled")
}

transition_rect_reset :: proc(state: ^Transition_Rect_State, value: Rect_I32) {
	assert(state != nil, "transition_rect_reset: nil state")
	assert(value.w >= 0 && value.h >= 0, "transition_rect_reset: negative extent")
	state^ = {
		current     = value,
		target      = value,
		initialized = true,
	}
	assert(transition_rect_settled(state), "transition_rect_reset: state not settled")
}

transition_f32_settled :: proc(state: ^Transition_F32_State) -> bool {
	assert(state != nil, "transition_f32_settled: nil state")
	return state.initialized && state.current == state.target
}

transition_color_settled :: proc(state: ^Transition_Color_State) -> bool {
	assert(state != nil, "transition_color_settled: nil state")
	return state.initialized && state.current == state.target
}

transition_rect_settled :: proc(state: ^Transition_Rect_State) -> bool {
	assert(state != nil, "transition_rect_settled: nil state")
	return state.initialized && state.current == state.target
}

transition_f32 :: proc(
	frame: ^Ui_Frame,
	state: ^Transition_F32_State,
	target: f32,
	options: Transition_Options = {},
) -> f32 {
	assert(frame != nil && frame.open, "transition_f32: invalid frame")
	assert(state != nil && transition_value_finite(target), "transition_f32: invalid value")
	speed := transition_speed(options)
	if !state.initialized || ui_frame_theme(frame).reduced_motion {
		transition_f32_reset(state, target)
		return target
	}
	assert(transition_value_finite(state.current), "transition_f32: corrupt current")
	state.target = target
	eased(&state.current, target, frame_input(frame).frame_time, speed)
	if !transition_f32_settled(state) do request_redraw(frame)
	return state.current
}

transition_color :: proc(
	frame: ^Ui_Frame,
	state: ^Transition_Color_State,
	target: Color,
	options: Transition_Options = {},
) -> Color {
	assert(frame != nil && frame.open, "transition_color: invalid frame")
	assert(state != nil, "transition_color: nil state")
	if !state.initialized || ui_frame_theme(frame).reduced_motion {
		transition_color_reset(state, target)
		return target
	}
	speed := transition_speed(options)
	state.target = target
	for index in 0 ..< len(state.current) {
		state.current[index] = transition_u8(state.current[index], target[index], frame, speed)
	}
	if !transition_color_settled(state) do request_redraw(frame)
	return state.current
}

transition_rect :: proc(
	frame: ^Ui_Frame,
	state: ^Transition_Rect_State,
	target: Rect_I32,
	options: Transition_Options = {},
) -> Rect_I32 {
	assert(frame != nil && frame.open, "transition_rect: invalid frame")
	assert(state != nil && target.w >= 0 && target.h >= 0, "transition_rect: invalid rect")
	if !state.initialized || ui_frame_theme(frame).reduced_motion {
		transition_rect_reset(state, target)
		return target
	}
	speed := transition_speed(options)
	state.target = target
	state.current.x = transition_i32(state.current.x, target.x, frame, speed)
	state.current.y = transition_i32(state.current.y, target.y, frame, speed)
	state.current.w = transition_i32(state.current.w, target.w, frame, speed)
	state.current.h = transition_i32(state.current.h, target.h, frame, speed)
	if !transition_rect_settled(state) do request_redraw(frame)
	return state.current
}

@(private = "file")
transition_speed :: proc(options: Transition_Options) -> f32 {
	speed := options.speed if options.speed != 0 else TRANSITION_SPEED_DEFAULT
	assert(transition_value_finite(speed), "transition: non-finite speed")
	assert(speed > 0, "transition: non-positive speed")
	return speed
}

@(private = "file")
transition_value_finite :: proc(value: f32) -> bool {
	return value == value && value != math.inf_f32(1) && value != math.inf_f32(-1)
}

@(private = "file")
transition_i32 :: proc(current, target: i32, frame: ^Ui_Frame, speed: f32) -> i32 {
	assert(frame != nil && speed > 0, "transition_i32: invalid argument")
	value := f64(current)
	factor := f64(clamp(speed * frame_input(frame).frame_time, 0, 1))
	if factor != factor do factor = 0
	value += (f64(target) - value) * factor
	if math.abs(f64(target) - value) < 0.5 do return target
	result := i64(math.round(value))
	result = clamp(result, i64(min(i32)), i64(max(i32)))
	if factor > 0 && i32(result) == current do return target
	return i32(result)
}

@(private = "file")
transition_u8 :: proc(current, target: u8, frame: ^Ui_Frame, speed: f32) -> u8 {
	value := transition_i32(i32(current), i32(target), frame, speed)
	return u8(clamp(value, 0, 255))
}

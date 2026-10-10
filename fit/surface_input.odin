package fit

import "ingot:ui"

surface_frame_time :: proc(surface: ^Surface) -> f32 {
	u := surface_ui(surface)
	return ui.frame_time(u.frame)
}

surface_timestamp :: proc(surface: ^Surface) -> f64 {
	u := surface_ui(surface)
	return ui.frame_timestamp(u.frame)
}

surface_dpi_scale :: proc(surface: ^Surface) -> f32 {
	u := surface_ui(surface)
	return ui.frame_dpi_scale(u.frame)
}

surface_fps :: proc(surface: ^Surface) -> i32 {
	u := surface_ui(surface)
	return ui.frame_fps(u.frame)
}

surface_monitor_refresh :: proc(surface: ^Surface) -> i32 {
	u := surface_ui(surface)
	return ui.frame_monitor_refresh(u.frame)
}

surface_key_pressed_repeat :: proc(surface: ^Surface, key: Key) -> bool {
	u := surface_ui(surface)
	return ui.is_key_pressed_repeat(u.frame, to_key(key))
}

surface_key_pressed_or_repeat :: proc(surface: ^Surface, key: Key) -> bool {
	u := surface_ui(surface)
	return ui.is_key_pressed_or_repeat(u.frame, to_key(key))
}

surface_key_released :: proc(surface: ^Surface, key: Key) -> bool {
	u := surface_ui(surface)
	return ui.is_key_released(u.frame, to_key(key))
}

surface_key_down :: proc(surface: ^Surface, key: Key) -> bool {
	u := surface_ui(surface)
	return ui.is_key_down(u.frame, to_key(key))
}

surface_modifier_down :: proc(surface: ^Surface) -> bool {
	return(
		surface_key_down(surface, .Left_Super) ||
		surface_key_down(surface, .Right_Super) ||
		surface_key_down(surface, .Left_Control) ||
		surface_key_down(surface, .Right_Control) \
	)
}

surface_mouse_released :: proc(surface: ^Surface, button: Mouse_Button) -> bool {
	u := surface_ui(surface)
	return ui.is_mouse_button_released(u.frame, to_mouse_button(button))
}

surface_mouse_delta :: proc(surface: ^Surface) -> Point {
	u := surface_ui(surface)
	return from_point(ui.get_mouse_delta(u.frame))
}

surface_mouse_moved :: proc(surface: ^Surface) -> bool {
	delta := surface_mouse_delta(surface)
	return delta.x != 0 || delta.y != 0
}

surface_characters :: proc(surface: ^Surface) -> []rune {
	u := surface_ui(surface)
	return ui.frame_characters(u.frame)
}

surface_characters_consume :: proc(surface: ^Surface) {
	u := surface_ui(surface)
	ui.frame_characters_consume(u.frame)
}

surface_clipboard :: proc(surface: ^Surface) -> string {
	u := surface_ui(surface)
	return ui.input_clipboard(ui.frame_input(u.frame))
}

surface_user_input_active :: proc(surface: ^Surface) -> bool {
	u := surface_ui(surface)
	return ui.frame_user_input_active(u.frame)
}

surface_to_local :: proc(surface: ^Surface, point: Point) -> Point {
	u := surface_ui(surface)
	return from_point(ui.frame_to_local(u.frame, ui.Vector2{point.x, point.y}))
}

request_redraw_in :: proc(surface: ^Surface, seconds: f64) {
	u := surface_ui(surface)
	ui.request_redraw_in(u.frame, seconds)
}

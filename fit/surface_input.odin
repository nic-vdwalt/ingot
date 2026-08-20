package fit

import "ingot:ui"

Surface_Frame_Time :: proc(surface: ^Surface) -> f32 {
	u := surface_ui(surface)
	return ui.frame_time(u.frame)
}

Surface_Timestamp :: proc(surface: ^Surface) -> f64 {
	u := surface_ui(surface)
	return ui.frame_timestamp(u.frame)
}

Surface_Dpi_Scale :: proc(surface: ^Surface) -> f32 {
	u := surface_ui(surface)
	return ui.frame_dpi_scale(u.frame)
}

Surface_Fps :: proc(surface: ^Surface) -> i32 {
	u := surface_ui(surface)
	return ui.frame_fps(u.frame)
}

Surface_Monitor_Refresh :: proc(surface: ^Surface) -> i32 {
	u := surface_ui(surface)
	return ui.frame_monitor_refresh(u.frame)
}

Surface_Key_Pressed_Repeat :: proc(surface: ^Surface, key: Key) -> bool {
	u := surface_ui(surface)
	return ui.is_key_pressed_repeat(u.frame, to_key(key))
}

Surface_Key_Pressed_Or_Repeat :: proc(surface: ^Surface, key: Key) -> bool {
	u := surface_ui(surface)
	return ui.is_key_pressed_or_repeat(u.frame, to_key(key))
}

Surface_Key_Released :: proc(surface: ^Surface, key: Key) -> bool {
	u := surface_ui(surface)
	return ui.is_key_released(u.frame, to_key(key))
}

Surface_Key_Down :: proc(surface: ^Surface, key: Key) -> bool {
	u := surface_ui(surface)
	return ui.is_key_down(u.frame, to_key(key))
}

Surface_Modifier_Down :: proc(surface: ^Surface) -> bool {
	return(
		Surface_Key_Down(surface, .Left_Super) ||
		Surface_Key_Down(surface, .Right_Super) ||
		Surface_Key_Down(surface, .Left_Control) ||
		Surface_Key_Down(surface, .Right_Control) \
	)
}

Surface_Mouse_Released :: proc(surface: ^Surface, button: Mouse_Button) -> bool {
	u := surface_ui(surface)
	return ui.is_mouse_button_released(u.frame, to_mouse_button(button))
}

Surface_Mouse_Delta :: proc(surface: ^Surface) -> Point {
	u := surface_ui(surface)
	return from_point(ui.get_mouse_delta(u.frame))
}

Surface_Mouse_Moved :: proc(surface: ^Surface) -> bool {
	delta := Surface_Mouse_Delta(surface)
	return delta.x != 0 || delta.y != 0
}

Surface_Characters :: proc(surface: ^Surface) -> []rune {
	u := surface_ui(surface)
	return ui.frame_characters(u.frame)
}

Surface_Characters_Consume :: proc(surface: ^Surface) {
	u := surface_ui(surface)
	ui.frame_characters_consume(u.frame)
}

Surface_Clipboard :: proc(surface: ^Surface) -> string {
	u := surface_ui(surface)
	return ui.input_clipboard(ui.frame_input(u.frame))
}

Surface_User_Input_Active :: proc(surface: ^Surface) -> bool {
	u := surface_ui(surface)
	return ui.frame_user_input_active(u.frame)
}

Surface_To_Local :: proc(surface: ^Surface, point: Point) -> Point {
	u := surface_ui(surface)
	return from_point(ui.frame_to_local(u.frame, ui.Vector2{point.x, point.y}))
}

Request_Redraw_In :: proc(surface: ^Surface, seconds: f64) {
	u := surface_ui(surface)
	ui.request_redraw_in(u.frame, seconds)
}

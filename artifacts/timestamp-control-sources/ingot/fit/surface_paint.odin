package fit

import "core:strings"
import "ingot:ui"

Surface_Fill_Circle :: proc(surface: ^Surface, center: Point, radius: f32, color: Color) {
	u := surface_ui(surface)
	ui.draw_circle_v(u.frame, ui.Vector2{center.x, center.y}, radius, ui.Color(color))
}

Surface_Stroke_Circle :: proc(surface: ^Surface, center: Point, radius: f32, color: Color) {
	u := surface_ui(surface)
	ui.draw_circle_lines_v(u.frame, ui.Vector2{center.x, center.y}, radius, ui.Color(color))
}

Surface_Ring :: proc(
	surface: ^Surface,
	center: Point,
	inner_radius, outer_radius, start_angle, end_angle: f32,
	segments: i32,
	color: Color,
) {
	u := surface_ui(surface)
	ui.draw_ring(
		u.frame,
		ui.Vector2{center.x, center.y},
		inner_radius,
		outer_radius,
		start_angle,
		end_angle,
		segments,
		ui.Color(color),
	)
}

Surface_Triangle :: proc(surface: ^Surface, a, b, c: Point, color: Color) {
	u := surface_ui(surface)
	ui.draw_triangle(
		u.frame,
		ui.Vector2{a.x, a.y},
		ui.Vector2{b.x, b.y},
		ui.Vector2{c.x, c.y},
		ui.Color(color),
	)
}

Surface_Text_Sized :: proc(surface: ^Surface, text: string, x, y, size: i32, color: Color) {
	u := surface_ui(surface)
	value := strings.clone_to_cstring(text, context.temp_allocator)
	ui.draw_text_frame(u.frame, value, x, y, size, ui.Color(color))
}

Surface_Text_Sized_Width :: proc(surface: ^Surface, text: string, size: i32) -> i32 {
	u := surface_ui(surface)
	value := strings.clone_to_cstring(text, context.temp_allocator)
	return ui.measure_text_frame(u.frame, value, size)
}

Surface_Text_Sized_Byte_At_X :: proc(surface: ^Surface, text: string, x, size: i32) -> int {
	assert(surface != nil, "Fit.Surface_Text_Sized_Byte_At_X: nil surface")
	assert(size > 0, "Fit.Surface_Text_Sized_Byte_At_X: invalid size")
	u := surface_ui(surface)
	column := ui.caret_pixel_to_col_frame(u.frame, text, x, size)
	return ui.caret_col_to_byte(text, column)
}

Surface_Rune_Width :: proc(surface: ^Surface, value: rune, size: i32) -> i32 {
	u := surface_ui(surface)
	return ui.rune_width_frame(u.frame, value, size)
}

Surface_Codepoint :: proc(surface: ^Surface, value: rune, x, y, size: i32, color: Color) {
	u := surface_ui(surface)
	ui.draw_codepoint_frame(u.frame, value, x, y, size, ui.Color(color))
}

Surface_Clip_Begin :: proc(surface: ^Surface, rect: Rect) {
	u := surface_ui(surface)
	ui.begin_scissor_mode(u.frame, rect.x, rect.y, rect.w, rect.h)
}

Surface_Clip_End :: proc(surface: ^Surface) {
	u := surface_ui(surface)
	ui.end_scissor_mode(u.frame)
}

Surface_Canvas_Begin :: proc(surface: ^Surface, rect: Rect, translation: Point = {}) {
	u := surface_ui(surface)
	ui.canvas_begin(u.frame, to_rect(rect), ui.Vector2{translation.x, translation.y})
}

Surface_Canvas_End :: proc(surface: ^Surface) {
	u := surface_ui(surface)
	ui.canvas_end(u.frame)
}

Surface_Canvas_Clear :: proc(surface: ^Surface, rect: Rect, color: Color) {
	u := surface_ui(surface)
	ui.canvas_clear(u.frame, to_rect(rect), ui.Color(color))
}

Surface_Pane_Origin_Push :: proc(surface: ^Surface, origin: Point) {
	u := surface_ui(surface)
	ui.ui_frame_pane_push(u.frame, ui.Vector2{origin.x, origin.y})
}

Surface_Pane_Origin_Pop :: proc(surface: ^Surface) {
	u := surface_ui(surface)
	ui.ui_frame_pane_pop(u.frame)
}

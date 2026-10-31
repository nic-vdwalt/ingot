package fit

import "core:strings"
import "ingot:ui"

surface_fill_circle :: proc(surface: ^Surface, center: Point, radius: f32, color: Color) {
	u := surface_ui(surface)
	ui.draw_circle_v(u.frame, ui.Vector2{center.x, center.y}, radius, ui.Color(color))
}

surface_stroke_circle :: proc(surface: ^Surface, center: Point, radius: f32, color: Color) {
	u := surface_ui(surface)
	ui.draw_circle_lines_v(u.frame, ui.Vector2{center.x, center.y}, radius, ui.Color(color))
}

surface_ring :: proc(
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

surface_triangle :: proc(surface: ^Surface, a, b, c: Point, color: Color) {
	u := surface_ui(surface)
	ui.draw_triangle(
		u.frame,
		ui.Vector2{a.x, a.y},
		ui.Vector2{b.x, b.y},
		ui.Vector2{c.x, c.y},
		ui.Color(color),
	)
}

surface_text_sized :: proc(surface: ^Surface, text: string, x, y, size: i32, color: Color) {
	u := surface_ui(surface)
	value := strings.clone_to_cstring(text, context.temp_allocator)
	ui.draw_text_frame(u.frame, value, x, y, size, ui.Color(color))
}

surface_text_sized_width :: proc(surface: ^Surface, text: string, size: i32) -> i32 {
	u := surface_ui(surface)
	value := strings.clone_to_cstring(text, context.temp_allocator)
	return ui.measure_text_frame(u.frame, value, size)
}

// surface_text_drawn_size returns the size text requested at `size` is
// actually drawn at by the active face.
surface_text_drawn_size :: proc(surface: ^Surface, size: i32) -> i32 {
	assert(surface != nil, "fit.surface_text_drawn_size: nil surface")
	assert(size > 0, "fit.surface_text_drawn_size: invalid size")
	u := surface_ui(surface)
	return ui.frame_text_size(u.frame, size)
}

surface_text_sized_byte_at_x :: proc(surface: ^Surface, text: string, x, size: i32) -> int {
	assert(surface != nil, "fit.surface_text_sized_byte_at_x: nil surface")
	assert(size > 0, "fit.surface_text_sized_byte_at_x: invalid size")
	u := surface_ui(surface)
	column := ui.caret_pixel_to_col_frame(u.frame, text, x, size)
	return ui.caret_col_to_byte(text, column)
}

surface_rune_width :: proc(surface: ^Surface, value: rune, size: i32) -> i32 {
	u := surface_ui(surface)
	return ui.rune_width_frame(u.frame, value, size)
}

// surface_reading_begin opens a reading region: text measured or drawn until
// the matching surface_reading_end uses the theme's reading face. Wrap both
// the measurement and the drawing of long-form text in a region.
surface_reading_begin :: proc(surface: ^Surface) {
	assert(surface != nil, "fit.surface_reading_begin: nil surface")
	u := surface_ui(surface)
	ui.frame_reading_begin(u.frame)
}

surface_reading_end :: proc(surface: ^Surface) {
	assert(surface != nil, "fit.surface_reading_end: nil surface")
	u := surface_ui(surface)
	ui.frame_reading_end(u.frame)
}

// surface_face_pin_begin pins the face text measured or drawn until the
// matching surface_face_pin_end uses, regardless of the theme's faces. Use it
// for content whose face must never follow the theme, such as an editor grid.
surface_face_pin_begin :: proc(surface: ^Surface, face: Font_Face) {
	assert(surface != nil, "fit.surface_face_pin_begin: nil surface")
	u := surface_ui(surface)
	ui.frame_face_pin_begin(u.frame, face)
}

surface_face_pin_end :: proc(surface: ^Surface) {
	assert(surface != nil, "fit.surface_face_pin_end: nil surface")
	u := surface_ui(surface)
	ui.frame_face_pin_end(u.frame)
}

surface_codepoint :: proc(surface: ^Surface, value: rune, x, y, size: i32, color: Color) {
	u := surface_ui(surface)
	ui.draw_codepoint_frame(u.frame, value, x, y, size, ui.Color(color))
}

surface_clip_begin :: proc(surface: ^Surface, rect: Rect) {
	u := surface_ui(surface)
	ui.begin_scissor_mode(u.frame, rect.x, rect.y, rect.w, rect.h)
}

surface_clip_end :: proc(surface: ^Surface) {
	u := surface_ui(surface)
	ui.end_scissor_mode(u.frame)
}

surface_canvas_begin :: proc(surface: ^Surface, rect: Rect, translation: Point = {}) {
	u := surface_ui(surface)
	ui.canvas_begin(u.frame, rect, ui.Vector2{translation.x, translation.y})
}

surface_canvas_end :: proc(surface: ^Surface) {
	u := surface_ui(surface)
	ui.canvas_end(u.frame)
}

surface_canvas_clear :: proc(surface: ^Surface, rect: Rect, color: Color) {
	u := surface_ui(surface)
	ui.canvas_clear(u.frame, rect, ui.Color(color))
}

surface_pane_origin_push :: proc(surface: ^Surface, origin: Point) {
	u := surface_ui(surface)
	ui.ui_frame_pane_push(u.frame, ui.Vector2{origin.x, origin.y})
}

surface_pane_origin_pop :: proc(surface: ^Surface) {
	u := surface_ui(surface)
	ui.ui_frame_pane_pop(u.frame)
}

// surface_draw_texture samples a renderer texture id (for example
// gfx.gpu_3d_target_color_texture(&target).id) into `dest`. `source` is in
// texture pixels: GPU-3D targets use a positive height, BeginTextureMode
// targets a negative one. End any GPU-3D pass before calling this.
surface_draw_texture :: proc(
	surface: ^Surface,
	texture: u32,
	source, dest: Float_Rect,
	tint: Color = {255, 255, 255, 255},
) {
	u := surface_ui(surface)
	ui.draw_texture(u.frame, texture, source, dest, ui.Color(tint))
}

// surface_icon draws a vector icon resolved through a theme ink, so the glyph
// follows every palette (including high contrast) without a literal color.
surface_icon :: proc(surface: ^Surface, icon: Icon, rect: Rect, ink: Ink = .Primary) {
	u := surface_ui(surface)
	assert(rect.w >= 0 && rect.h >= 0, "fit.surface_icon: negative rect")
	ui.draw_icon_frame(u.frame, icon, rect, ui.text_ink(u.frame, ink))
}

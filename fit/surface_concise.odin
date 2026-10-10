package fit

viewport :: proc(surface: ^Surface) -> Rect {
	return surface_viewport(surface)
}

pane_origin :: proc(surface: ^Surface) -> Point {
	return surface_pane_origin(surface)
}

cull_bounds :: proc(surface: ^Surface) -> (top, bottom: i32) {
	return surface_cull_bounds(surface)
}

get_metrics :: proc(surface: ^Surface) -> Metrics {
	return surface_metrics(surface)
}

get_theme_tokens :: proc(surface: ^Surface) -> Theme_Tokens {
	return surface_theme_tokens(surface)
}

space_px :: proc(surface: ^Surface, space: Space) -> i32 {
	return surface_space(surface, space)
}

pigment_color :: proc(surface: ^Surface, pigment: Pigment) -> Color {
	return surface_pigment(surface, pigment)
}

text_size :: proc(surface: ^Surface, role: Text_Role) -> i32 {
	return surface_text_size(surface, role)
}

text_line_height :: proc(surface: ^Surface, role: Text_Role) -> i32 {
	return surface_text_line_height(surface, role)
}

text_metrics_for_size :: proc(surface: ^Surface, font_size: i32) -> (Text_Metrics, bool) {
	return surface_text_metrics(surface, font_size)
}

reduced_motion :: proc(surface: ^Surface) -> bool {
	return surface_reduced_motion(surface)
}

text_width :: proc(surface: ^Surface, text: string, role: Text_Role = .Body) -> i32 {
	return surface_text_width(surface, text, role)
}

text :: proc(
	surface: ^Surface,
	text: string,
	x, y: i32,
	role: Text_Role = .Body,
	ink: Ink = .Primary,
) {
	surface_text(surface, text, x, y, role, ink)
}

text_truncated :: proc(
	surface: ^Surface,
	text: string,
	x, y, width: i32,
	role: Text_Role = .Body,
	ink: Ink = .Primary,
) {
	surface_text_truncated(surface, text, x, y, width, role, ink)
}

text_wrapped :: proc(
	surface: ^Surface,
	text: string,
	x, y, width: i32,
	color: Color,
	font_size, line_height: i32,
) {
	surface_text_wrapped(surface, text, x, y, width, color, font_size, line_height)
}

text_wrapped_height :: proc(
	surface: ^Surface,
	text: string,
	width, font_size, line_height: i32,
) -> i32 {
	return surface_text_wrapped_height(surface, text, width, font_size, line_height)
}

fill_rect_i32 :: proc(surface: ^Surface, rect: Rect, color: Color) {
	surface_fill_rect(surface, rect, color)
}

fill_rect_f32 :: proc(surface: ^Surface, rect: Float_Rect, color: Color) {
	surface_fill_float_rect(surface, rect, color)
}

fill_rect :: proc {
	fill_rect_i32,
	fill_rect_f32,
}

stroke_rect :: proc(surface: ^Surface, rect: Rect, color: Color) {
	surface_stroke_rect(surface, rect, color)
}

line :: proc(surface: ^Surface, from, to: Point, thickness: f32, color: Color) {
	surface_line(surface, from, to, thickness, color)
}

fill_rounded_rect :: proc(
	surface: ^Surface,
	rect: Float_Rect,
	roundness: f32,
	segments: i32,
	color: Color,
) {
	surface_fill_rounded_rect(surface, rect, roundness, segments, color)
}

stroke_rounded_rect :: proc(
	surface: ^Surface,
	rect: Float_Rect,
	roundness: f32,
	segments: i32,
	thickness: f32,
	color: Color,
) {
	surface_stroke_rounded_rect(surface, rect, roundness, segments, thickness, color)
}

draw_surface :: proc(
	surface: ^Surface,
	rect: Float_Rect,
	kind: Surface_Kind,
	state: Visual_State = .Rest,
	radius: Radius = .None,
	border: Border = .None,
	elevation: Elevation = .Flat,
) {
	surface_draw_surface(surface, rect, kind, state, radius, border, elevation)
}

interact :: proc(surface: ^Surface, rect: Float_Rect) -> Interaction {
	return surface_interact(surface, rect)
}

key_pressed :: proc(surface: ^Surface, key: Key) -> bool {
	return surface_key_pressed(surface, key)
}

key_pressed_consume :: proc(surface: ^Surface, key: Key) {
	surface_key_pressed_consume(surface, key)
}

mouse_pressed :: proc(surface: ^Surface, button: Mouse_Button) -> bool {
	return surface_mouse_pressed(surface, button)
}

mouse_down :: proc(surface: ^Surface, button: Mouse_Button) -> bool {
	return surface_mouse_down(surface, button)
}

mouse_position :: proc(surface: ^Surface) -> Point {
	return surface_mouse_position(surface)
}

wheel_v :: proc(surface: ^Surface) -> Point {
	return surface_wheel_v(surface)
}

wheel :: proc(surface: ^Surface) -> f32 {
	return surface_wheel(surface)
}

request_cursor :: proc(surface: ^Surface, cursor: Cursor) {
	surface_request_cursor(surface, cursor)
}

pane_begin :: proc(
	surface: ^Surface,
	state: ^Pane_State,
	rect: Rect,
	padding: i32 = 8,
	keyboard: bool = true,
	keyboard_unhovered: bool = false,
) -> i32 {
	return surface_pane_begin(surface, state, rect, padding, keyboard, keyboard_unhovered)
}

pane_end :: proc(
	surface: ^Surface,
	state: ^Pane_State,
	rect: Rect,
	content_y: i32,
	padding: i32 = 8,
) {
	surface_pane_end(surface, state, rect, content_y, padding)
}

grid_visible_range :: proc(
	surface: ^Surface,
	rect: Rect,
	columns, row_height, gap_y, count, top, bottom: i32,
) -> Visible_Range {
	return surface_grid_visible_range(
		surface,
		rect,
		columns,
		row_height,
		gap_y,
		count,
		top,
		bottom,
	)
}

layer_begin :: proc(surface: ^Surface, z: Z_Order, claim: Float_Rect = {}) {
	surface_layer_begin(surface, z, claim)
}

layer_end :: proc(surface: ^Surface) {
	surface_layer_end(surface)
}

draw_shadow :: proc(surface: ^Surface, rect: Float_Rect, radius: Radius, elevation: Elevation) {
	surface_draw_shadow(surface, rect, radius, elevation)
}

draw_rules :: proc(surface: ^Surface, rect: Float_Rect, spacing: i32, color: Color) {
	surface_draw_rules(surface, rect, spacing, color)
}

draw_margin_rule :: proc(surface: ^Surface, rect: Float_Rect, inset: i32, color: Color) {
	surface_draw_margin_rule(surface, rect, inset, color)
}

draw_hand_underline :: proc(surface: ^Surface, x, y, width: i32, color: Color) {
	surface_draw_hand_underline(surface, x, y, width, color)
}

draw_dot_grid :: proc(surface: ^Surface, rect: Float_Rect, spacing: i32, color: Color) {
	surface_draw_dot_grid(surface, rect, spacing, color)
}

draw_highlight :: proc(surface: ^Surface, rect: Float_Rect, color: Color) {
	surface_draw_highlight(surface, rect, color)
}

draw_scribble :: proc(surface: ^Surface, rect: Float_Rect, color: Color) {
	surface_draw_scribble(surface, rect, color)
}

draw_tape :: proc(surface: ^Surface, rect: Float_Rect, length: f32, color: Color) {
	surface_draw_tape(surface, rect, length, color)
}

draw_dog_ear :: proc(surface: ^Surface, rect: Float_Rect, size: f32, fold, shade: Color) {
	surface_draw_dog_ear(surface, rect, size, fold, shade)
}

draw_paper_tooth :: proc(surface: ^Surface, rect: Float_Rect, color: Color) {
	surface_draw_paper_tooth(surface, rect, color)
}

draw_wash :: proc(surface: ^Surface, rect: Float_Rect, color: Color) {
	surface_draw_wash(surface, rect, color)
}

draw_pigment_block :: proc(surface: ^Surface, rect: Float_Rect, color: Color) {
	surface_draw_pigment_block(surface, rect, color)
}

draw_chalk_highlight :: proc(surface: ^Surface, rect: Float_Rect, radius: Radius) {
	surface_draw_chalk_highlight(surface, rect, radius)
}

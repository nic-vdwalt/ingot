package fit

import "ingot:ui"

Surface_Viewport :: proc(surface: ^Surface) -> Rect {
	u := surface_ui(surface)
	return from_rect(ui.frame_viewport(u.frame))
}

Surface_Pane_Origin :: proc(surface: ^Surface) -> Point {
	u := surface_ui(surface)
	return from_point(ui.frame_pane_origin(u.frame))
}

Surface_Scale :: proc(surface: ^Surface, value: i32) -> i32 {
	u := surface_ui(surface)
	return ui.ui_frame_sc(u.frame, value)
}

Surface_Metrics :: proc(surface: ^Surface) -> Metrics {
	u := surface_ui(surface)
	metrics := ui.ui_frame_metrics(u.frame)
	return {
		font_title = metrics.FONT_SIZE_TITLE,
		font_body = metrics.FONT_SIZE_BODY,
		font_label = metrics.FONT_SIZE_LABEL,
		font_note = metrics.FONT_SIZE_NOTE,
		line_height = metrics.LINE_HEIGHT,
		tab_bar_height = metrics.TAB_BAR_HEIGHT,
		padding = metrics.PADDING,
		row_small = metrics.ROW_H_SM,
		row_medium = metrics.ROW_H_MD,
		control_gap = metrics.CONTROL_GAP,
	}
}

Surface_Theme :: proc(surface: ^Surface) -> Theme {
	u := surface_ui(surface)
	return {inner = ui.ui_frame_theme(u.frame)^}
}

Surface_Theme_Color :: proc(surface: ^Surface, ink: Ink) -> Color {
	u := surface_ui(surface)
	return Color(ui.text_ink(u.frame, ui.Ink(ink)))
}

Surface_Resolve_Colors :: proc(
	surface: ^Surface,
	kind: Surface_Kind,
	state: Visual_State = .Rest,
) -> Surface_Colors {
	u := surface_ui(surface)
	colors := ui.surface_colors(u.frame, ui.Surface(kind), ui.Visual_State(state))
	return {Color(colors.bg), Color(colors.fg), Color(colors.border)}
}

Surface_Pigment :: proc(surface: ^Surface, pigment: Pigment) -> Color {
	theme := Surface_Theme(surface)
	return Theme_Pigment(theme, pigment)
}

Surface_Space :: proc(surface: ^Surface, space: Space) -> i32 {
	u := surface_ui(surface)
	return ui.space_pixels(u.frame, ui.Space(space))
}

Surface_Text_Size :: proc(surface: ^Surface, role: Text_Role) -> i32 {
	u := surface_ui(surface)
	return ui.text_role_size(u.frame, ui.Text_Role(role))
}

Surface_Text_Line_Height :: proc(surface: ^Surface, role: Text_Role) -> i32 {
	u := surface_ui(surface)
	return ui.text_role_line_height(u.frame, ui.Text_Role(role))
}

Surface_Text_Width :: proc(surface: ^Surface, text: string, role: Text_Role = .Body) -> i32 {
	u := surface_ui(surface)
	return ui.text_width(u.frame, text, ui.Text_Role(role))
}

Surface_Text :: proc(
	surface: ^Surface,
	text: string,
	x, y: i32,
	role: Text_Role = .Body,
	ink: Ink = .Primary,
) {
	u := surface_ui(surface)
	ui.text(u.frame, text, x, y, ui.Text_Role(role), ui.Ink(ink))
}

Surface_Text_Truncated :: proc(
	surface: ^Surface,
	text: string,
	x, y, width: i32,
	role: Text_Role = .Body,
	ink: Ink = .Primary,
) {
	u := surface_ui(surface)
	ui.text_truncated(u.frame, text, x, y, width, ui.Text_Role(role), ui.Ink(ink))
}

Surface_Fill_Rect :: proc(surface: ^Surface, rect: Rect, color: Color) {
	u := surface_ui(surface)
	ui.draw_rectangle(u.frame, rect.x, rect.y, rect.w, rect.h, ui.Color(color))
}

Surface_Fill_Float_Rect :: proc(surface: ^Surface, rect: Float_Rect, color: Color) {
	u := surface_ui(surface)
	ui.draw_rectangle_rec(u.frame, to_float_rect(rect), ui.Color(color))
}

Surface_Stroke_Rect :: proc(surface: ^Surface, rect: Rect, color: Color) {
	u := surface_ui(surface)
	ui.draw_rectangle_lines(u.frame, rect.x, rect.y, rect.w, rect.h, ui.Color(color))
}

Surface_Draw_Surface :: proc(
	surface: ^Surface,
	rect: Float_Rect,
	kind: Surface_Kind,
	state: Visual_State = .Rest,
	radius: Radius = .None,
	border: Border = .None,
	elevation: Elevation = .Flat,
) {
	u := surface_ui(surface)
	ui.draw_surface(
		u.frame,
		to_float_rect(rect),
		ui.Surface(kind),
		ui.Visual_State(state),
		ui.Radius(radius),
		ui.Border(border),
		ui.Elevation(elevation),
	)
}

Surface_Interact :: proc(surface: ^Surface, rect: Float_Rect) -> Interaction {
	u := surface_ui(surface)
	result := ui.interact(u.frame, to_float_rect(rect))
	return {result.hovered, result.pressed, result.held, result.released, result.clicked}
}

Surface_Key_Pressed :: proc(surface: ^Surface, key: Key) -> bool {
	u := surface_ui(surface)
	return ui.is_key_pressed(u.frame, ui.Key(key))
}

Surface_Mouse_Pressed :: proc(surface: ^Surface, button: Mouse_Button) -> bool {
	u := surface_ui(surface)
	return ui.is_mouse_button_pressed(u.frame, ui.Mouse_Button(button))
}

Surface_Mouse_Position :: proc(surface: ^Surface) -> Point {
	u := surface_ui(surface)
	return from_point(ui.get_mouse_position(u.frame))
}

Surface_Wheel :: proc(surface: ^Surface) -> f32 {
	u := surface_ui(surface)
	return ui.get_wheel_move(u.frame)
}

Surface_Request_Cursor :: proc(surface: ^Surface, cursor: Cursor) {
	u := surface_ui(surface)
	ui.request_cursor(u.frame, ui.Cursor(cursor))
}

Request_Redraw :: proc(surface: ^Surface) {
	u := surface_ui(surface)
	ui.request_redraw(u.frame)
}

Surface_Region_Begin :: proc(surface: ^Surface, region: ^Region, rect: Rect, gap: Space = .None) {
	u := surface_ui(surface)
	assert(region != nil && !region.inner.open, "Fit.Surface_Region_Begin: invalid region")
	ui.begin(&region.inner, u.frame, to_rect(rect), gap = ui.Space(gap))
}

Surface_Region_End :: proc(region: ^Region) -> i32 {
	assert(region != nil && region.inner.open, "Fit.Surface_Region_End: region not open")
	return ui.end(&region.inner)
}

Surface_Pane_Begin :: proc(
	surface: ^Surface,
	state: ^Pane_State,
	rect: Rect,
	padding: i32 = 8,
	keyboard: bool = true,
) -> i32 {
	u := surface_ui(surface)
	assert(state != nil, "Fit.Surface_Pane_Begin: nil state")
	return ui.pane_begin(u.frame, &state.inner, to_rect(rect), pad = padding, keyboard = keyboard)
}

Surface_Pane_End :: proc(
	surface: ^Surface,
	state: ^Pane_State,
	rect: Rect,
	content_y: i32,
	padding: i32 = 8,
) {
	u := surface_ui(surface)
	assert(state != nil, "Fit.Surface_Pane_End: nil state")
	ui.pane_end(u.frame, &state.inner, to_rect(rect), content_y, pad = padding)
}

Pane_Reset :: proc(state: ^Pane_State) {
	assert(state != nil, "Fit.Pane_Reset: nil state")
	ui.pane_reset(&state.inner)
}

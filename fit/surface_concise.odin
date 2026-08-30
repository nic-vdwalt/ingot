package fit

Viewport :: proc(surface: ^Surface) -> Rect {
	return Surface_Viewport(surface)
}

Pane_Origin :: proc(surface: ^Surface) -> Point {
	return Surface_Pane_Origin(surface)
}

Cull_Bounds :: proc(surface: ^Surface) -> (top, bottom: i32) {
	return Surface_Cull_Bounds(surface)
}

Get_Metrics :: proc(surface: ^Surface) -> Metrics {
	return Surface_Metrics(surface)
}

Get_Theme_Tokens :: proc(surface: ^Surface) -> Theme_Tokens {
	return Surface_Theme_Tokens(surface)
}

Space_Px :: proc(surface: ^Surface, space: Space) -> i32 {
	return Surface_Space(surface, space)
}

Pigment_Color :: proc(surface: ^Surface, pigment: Pigment) -> Color {
	return Surface_Pigment(surface, pigment)
}

Text_Size :: proc(surface: ^Surface, role: Text_Role) -> i32 {
	return Surface_Text_Size(surface, role)
}

Text_Line_Height :: proc(surface: ^Surface, role: Text_Role) -> i32 {
	return Surface_Text_Line_Height(surface, role)
}

Text_Metrics_For_Size :: proc(surface: ^Surface, font_size: i32) -> (Text_Metrics, bool) {
	return Surface_Text_Metrics(surface, font_size)
}

Reduced_Motion :: proc(surface: ^Surface) -> bool {
	return Surface_Reduced_Motion(surface)
}

Text_Width :: proc(surface: ^Surface, text: string, role: Text_Role = .Body) -> i32 {
	return Surface_Text_Width(surface, text, role)
}

Text :: proc(
	surface: ^Surface,
	text: string,
	x, y: i32,
	role: Text_Role = .Body,
	ink: Ink = .Primary,
) {
	Surface_Text(surface, text, x, y, role, ink)
}

Text_Truncated :: proc(
	surface: ^Surface,
	text: string,
	x, y, width: i32,
	role: Text_Role = .Body,
	ink: Ink = .Primary,
) {
	Surface_Text_Truncated(surface, text, x, y, width, role, ink)
}

Text_Wrapped :: proc(
	surface: ^Surface,
	text: string,
	x, y, width: i32,
	color: Color,
	font_size, line_height: i32,
) {
	Surface_Text_Wrapped(surface, text, x, y, width, color, font_size, line_height)
}

fill_rect_i32 :: proc(surface: ^Surface, rect: Rect, color: Color) {
	Surface_Fill_Rect(surface, rect, color)
}

fill_rect_f32 :: proc(surface: ^Surface, rect: Float_Rect, color: Color) {
	Surface_Fill_Float_Rect(surface, rect, color)
}

Fill_Rect :: proc {
	fill_rect_i32,
	fill_rect_f32,
}

Stroke_Rect :: proc(surface: ^Surface, rect: Rect, color: Color) {
	Surface_Stroke_Rect(surface, rect, color)
}

Line :: proc(surface: ^Surface, from, to: Point, thickness: f32, color: Color) {
	Surface_Line(surface, from, to, thickness, color)
}

Fill_Rounded_Rect :: proc(
	surface: ^Surface,
	rect: Float_Rect,
	roundness: f32,
	segments: i32,
	color: Color,
) {
	Surface_Fill_Rounded_Rect(surface, rect, roundness, segments, color)
}

Stroke_Rounded_Rect :: proc(
	surface: ^Surface,
	rect: Float_Rect,
	roundness: f32,
	segments: i32,
	thickness: f32,
	color: Color,
) {
	Surface_Stroke_Rounded_Rect(surface, rect, roundness, segments, thickness, color)
}

Draw_Surface :: proc(
	surface: ^Surface,
	rect: Float_Rect,
	kind: Surface_Kind,
	state: Visual_State = .Rest,
	radius: Radius = .None,
	border: Border = .None,
	elevation: Elevation = .Flat,
) {
	Surface_Draw_Surface(surface, rect, kind, state, radius, border, elevation)
}

Interact :: proc(surface: ^Surface, rect: Float_Rect) -> Interaction {
	return Surface_Interact(surface, rect)
}

Key_Pressed :: proc(surface: ^Surface, key: Key) -> bool {
	return Surface_Key_Pressed(surface, key)
}

Key_Pressed_Consume :: proc(surface: ^Surface, key: Key) {
	Surface_Key_Pressed_Consume(surface, key)
}

Mouse_Pressed :: proc(surface: ^Surface, button: Mouse_Button) -> bool {
	return Surface_Mouse_Pressed(surface, button)
}

Mouse_Down :: proc(surface: ^Surface, button: Mouse_Button) -> bool {
	return Surface_Mouse_Down(surface, button)
}

Mouse_Position :: proc(surface: ^Surface) -> Point {
	return Surface_Mouse_Position(surface)
}

Wheel :: proc(surface: ^Surface) -> f32 {
	return Surface_Wheel(surface)
}

Request_Cursor :: proc(surface: ^Surface, cursor: Cursor) {
	Surface_Request_Cursor(surface, cursor)
}

Pane_Begin :: proc(
	surface: ^Surface,
	state: ^Pane_State,
	rect: Rect,
	padding: i32 = 8,
	keyboard: bool = true,
) -> i32 {
	return Surface_Pane_Begin(surface, state, rect, padding, keyboard)
}

Pane_End :: proc(
	surface: ^Surface,
	state: ^Pane_State,
	rect: Rect,
	content_y: i32,
	padding: i32 = 8,
) {
	Surface_Pane_End(surface, state, rect, content_y, padding)
}

Grid_Visible_Range :: proc(
	surface: ^Surface,
	rect: Rect,
	columns, row_height, gap_y, count, top, bottom: i32,
) -> Visible_Range {
	return Surface_Grid_Visible_Range(
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

Layer_Begin :: proc(surface: ^Surface, z: Z_Order, claim: Float_Rect = {}) {
	Surface_Layer_Begin(surface, z, claim)
}

Layer_End :: proc(surface: ^Surface) {
	Surface_Layer_End(surface)
}

Draw_Shadow :: proc(surface: ^Surface, rect: Float_Rect, radius: Radius, elevation: Elevation) {
	Surface_Draw_Shadow(surface, rect, radius, elevation)
}

Draw_Rules :: proc(surface: ^Surface, rect: Float_Rect, spacing: i32, color: Color) {
	Surface_Draw_Rules(surface, rect, spacing, color)
}

Draw_Margin_Rule :: proc(surface: ^Surface, rect: Float_Rect, inset: i32, color: Color) {
	Surface_Draw_Margin_Rule(surface, rect, inset, color)
}

Draw_Hand_Underline :: proc(surface: ^Surface, x, y, width: i32, color: Color) {
	Surface_Draw_Hand_Underline(surface, x, y, width, color)
}

Draw_Dot_Grid :: proc(surface: ^Surface, rect: Float_Rect, spacing: i32, color: Color) {
	Surface_Draw_Dot_Grid(surface, rect, spacing, color)
}

Draw_Highlight :: proc(surface: ^Surface, rect: Float_Rect, color: Color) {
	Surface_Draw_Highlight(surface, rect, color)
}

Draw_Scribble :: proc(surface: ^Surface, rect: Float_Rect, color: Color) {
	Surface_Draw_Scribble(surface, rect, color)
}

Draw_Tape :: proc(surface: ^Surface, rect: Float_Rect, length: f32, color: Color) {
	Surface_Draw_Tape(surface, rect, length, color)
}

Draw_Dog_Ear :: proc(surface: ^Surface, rect: Float_Rect, size: f32, fold, shade: Color) {
	Surface_Draw_Dog_Ear(surface, rect, size, fold, shade)
}

Draw_Paper_Tooth :: proc(surface: ^Surface, rect: Float_Rect, color: Color) {
	Surface_Draw_Paper_Tooth(surface, rect, color)
}

Draw_Wash :: proc(surface: ^Surface, rect: Float_Rect, color: Color) {
	Surface_Draw_Wash(surface, rect, color)
}

Draw_Pigment_Block :: proc(surface: ^Surface, rect: Float_Rect, color: Color) {
	Surface_Draw_Pigment_Block(surface, rect, color)
}

Draw_Chalk_Highlight :: proc(surface: ^Surface, rect: Float_Rect, radius: Radius) {
	Surface_Draw_Chalk_Highlight(surface, rect, radius)
}

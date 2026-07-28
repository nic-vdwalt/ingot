package ui

frame_paint_list :: proc(frame: ^Ui_Frame, channel: Paint_Channel = .Main) -> ^Paint_List {
	assert(frame != nil && frame.open, "frame_paint_list: invalid frame")
	assert(frame.output != nil, "frame_paint_list: missing output")
	if channel == .Overlay do return &frame.output.overlay
	return &frame.output.main
}

paint_command_to_screen :: proc(frame: ^Ui_Frame, command: Paint_Command) -> Paint_Command {
	assert(frame != nil && frame.open, "paint_command_to_screen: invalid frame")
	origin := frame_pane_origin(frame)
	result := command
	switch command.kind {
	case .Rectangle, .Rectangle_Outline, .Rectangle_Rounded,
	     .Rectangle_Rounded_Outline, .Rectangle_Gradient_V:
		result.rect.x += origin.x
		result.rect.y += origin.y
	case .Line:
		result.p0 += origin
		result.p1 += origin
	case .Triangle:
		result.p0 += origin
		result.p1 += origin
		result.p2 += origin
	case .Circle, .Circle_Outline, .Ring, .Text, .Codepoint:
		result.p0 += origin
	case .Clip_Begin, .Clip_End:
		assert(false, "paint_command_to_screen: structural command")
	}
	return result
}

frame_paint_push :: proc(frame: ^Ui_Frame, command: Paint_Command) -> bool {
	assert(frame != nil && frame.open, "frame_paint_push: invalid frame")
	return paint_push(frame_paint_list(frame), paint_command_to_screen(frame, command))
}

frame_paint_push_text :: proc(frame: ^Ui_Frame, command: Paint_Command, text: string) -> bool {
	assert(frame != nil && frame.open, "frame_paint_push_text: invalid frame")
	return paint_push_text(frame_paint_list(frame), paint_command_to_screen(frame, command), text)
}

draw_rectangle :: proc(frame: ^Ui_Frame, x, y, width, height: i32, color: Color) {
	assert(frame != nil, "draw_rectangle: nil frame")
	frame_paint_push(
		frame,
		{kind = .Rectangle, rect = {f32(x), f32(y), f32(width), f32(height)}, color = color},
	)
}

draw_rectangle_rec :: proc(frame: ^Ui_Frame, rect: Rectangle, color: Color) {
	frame_paint_push(frame, {kind = .Rectangle, rect = rect, color = color})
}

draw_rectangle_lines :: proc(frame: ^Ui_Frame, x, y, width, height: i32, color: Color) {
	draw_rectangle_lines_ex(frame, {f32(x), f32(y), f32(width), f32(height)}, 1, color)
}

draw_rectangle_lines_ex :: proc(frame: ^Ui_Frame, rect: Rectangle, thickness: f32, color: Color) {
	assert(frame != nil, "draw_rectangle_lines_ex: nil frame")
	frame_paint_push(
		frame,
		{kind = .Rectangle_Outline, rect = rect, thickness = thickness, color = color},
	)
}

draw_rectangle_rounded :: proc(
	frame: ^Ui_Frame,
	rect: Rectangle,
	roundness: f32,
	segments: i32,
	color: Color,
) {
	assert(frame != nil, "draw_rectangle_rounded: nil frame")
	frame_paint_push(
		frame,
		{
			kind = .Rectangle_Rounded,
			rect = rect,
			roundness = roundness,
			segments = segments,
			color = color,
		},
	)
}

draw_rectangle_rounded_lines_ex :: proc(
	frame: ^Ui_Frame,
	rect: Rectangle,
	roundness: f32,
	segments: i32,
	thickness: f32,
	color: Color,
) {
	assert(frame != nil, "draw_rectangle_rounded_lines_ex: nil frame")
	frame_paint_push(
		frame,
		{
			kind = .Rectangle_Rounded_Outline,
			rect = rect,
			roundness = roundness,
			segments = segments,
			thickness = thickness,
			color = color,
		},
	)
}

draw_rectangle_gradient_v :: proc(frame: ^Ui_Frame, x, y, width, height: i32, top, bottom: Color) {
	assert(frame != nil, "draw_rectangle_gradient_v: nil frame")
	frame_paint_push(
		frame,
		{
			kind = .Rectangle_Gradient_V,
			rect = {f32(x), f32(y), f32(width), f32(height)},
			color = top,
			color_end = bottom,
		},
	)
}

draw_line :: proc(frame: ^Ui_Frame, x0, y0, x1, y1: i32, color: Color) {
	draw_line_ex(frame, {f32(x0), f32(y0)}, {f32(x1), f32(y1)}, 1, color)
}

draw_line_ex :: proc(frame: ^Ui_Frame, p0, p1: Vector2, thickness: f32, color: Color) {
	assert(frame != nil, "draw_line_ex: nil frame")
	frame_paint_push(
		frame,
		{kind = .Line, p0 = p0, p1 = p1, thickness = thickness, color = color},
	)
}

draw_circle :: proc(frame: ^Ui_Frame, x, y: i32, radius: f32, color: Color) {
	draw_circle_v(frame, {f32(x), f32(y)}, radius, color)
}

draw_circle_v :: proc(frame: ^Ui_Frame, center: Vector2, radius: f32, color: Color) {
	assert(frame != nil, "draw_circle_v: nil frame")
	frame_paint_push(
		frame,
		{kind = .Circle, p0 = center, outer_radius = radius, color = color},
	)
}

draw_circle_lines_v :: proc(frame: ^Ui_Frame, center: Vector2, radius: f32, color: Color) {
	assert(frame != nil, "draw_circle_lines_v: nil frame")
	frame_paint_push(
		frame,
		{kind = .Circle_Outline, p0 = center, outer_radius = radius, color = color},
	)
}

draw_ring :: proc(
	frame: ^Ui_Frame,
	center: Vector2,
	inner_radius, outer_radius, start_angle, end_angle: f32,
	segments: i32,
	color: Color,
) {
	assert(frame != nil, "draw_ring: nil frame")
	frame_paint_push(
		frame,
		{
			kind = .Ring,
			p0 = center,
			inner_radius = inner_radius,
			outer_radius = outer_radius,
			start_angle = start_angle,
			end_angle = end_angle,
			segments = segments,
			color = color,
		},
	)
}

draw_triangle :: proc(frame: ^Ui_Frame, p0, p1, p2: Vector2, color: Color) {
	assert(frame != nil, "draw_triangle: nil frame")
	frame_paint_push(
		frame,
		{kind = .Triangle, p0 = p0, p1 = p1, p2 = p2, color = color},
	)
}

begin_scissor_mode :: proc(frame: ^Ui_Frame, x, y, width, height: i32) {
	assert(frame != nil && frame.open, "begin_scissor_mode: invalid frame")
	origin := frame_pane_origin(frame)
	paint_clip_begin(
		frame_paint_list(frame),
		{
			f32(x) + origin.x,
			f32(y) + origin.y,
			f32(max(width, 0)),
			f32(max(height, 0)),
		},
	)
}

end_scissor_mode :: proc(frame: ^Ui_Frame) {
	assert(frame != nil && frame.open, "end_scissor_mode: invalid frame")
	paint_clip_end(frame_paint_list(frame))
}

canvas_begin :: proc(frame: ^Ui_Frame, rect: Rect_I32, translation: Vector2 = {}) {
	assert(frame != nil && frame.open, "canvas_begin: invalid frame")
	assert(rect.w >= 0 && rect.h >= 0, "canvas_begin: negative rect")
	parent := frame_pane_origin(frame)
	paint_clip_begin(
		frame_paint_list(frame),
		{parent.x + f32(rect.x), parent.y + f32(rect.y), f32(rect.w), f32(rect.h)},
	)
	ui_frame_pane_push(frame, Vector2{f32(rect.x), f32(rect.y)} + translation)
	assert(frame.pane_count > 0 && frame.pane_count <= MAX_PANE_SCOPES)
}

canvas_end :: proc(frame: ^Ui_Frame) {
	assert(frame != nil && frame.open, "canvas_end: invalid frame")
	assert(frame.pane_count > 0, "canvas_end: no canvas")
	paint_clip_end(frame_paint_list(frame))
	ui_frame_pane_pop(frame)
	assert(frame.pane_count >= 0 && frame.pane_count < MAX_PANE_SCOPES)
}

canvas_clear :: proc(frame: ^Ui_Frame, rect: Rect_I32, color: Color) {
	assert(frame != nil && frame.open, "canvas_clear: invalid frame")
	assert(rect.w >= 0 && rect.h >= 0, "canvas_clear: negative rect")
	draw_rectangle_rec(frame, Rect{0, 0, f32(rect.w), f32(rect.h)}, color)
}

draw_text_command :: proc(
	frame: ^Ui_Frame,
	text: string,
	x, y, size: i32,
	color: Color,
	font: Font_Id = 0,
) {
	assert(frame != nil, "draw_text_command: nil frame")
	command := Paint_Command {
		kind      = .Text,
		p0        = {f32(x), f32(y)},
		color     = color,
		font      = font,
		font_size = f32(size),
	}
	frame_paint_push_text(frame, command, text)
}

draw_cstring_command :: proc(
	frame: ^Ui_Frame,
	text: cstring,
	x, y, size: i32,
	color: Color,
	font: Font_Id = 0,
) {
	draw_text_command(frame, string(text), x, y, size, color, font)
}

draw_codepoint_command :: proc(
	frame: ^Ui_Frame,
	codepoint: rune,
	x, y, size: i32,
	color: Color,
	font: Font_Id = 0,
) {
	assert(frame != nil, "draw_codepoint_command: nil frame")
	frame_paint_push(
		frame,
		{
			kind = .Codepoint,
			p0 = {f32(x), f32(y)},
			color = color,
			font = font,
			font_size = f32(size),
			codepoint = codepoint,
		},
	)
}

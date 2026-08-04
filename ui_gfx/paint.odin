package ui_gfx

import "core:strings"
import rl "ingot:gfx"
import "ingot:ui"

replay :: proc(adapter: ^Adapter, output: ^ui.Ui_Output) {
	assert(adapter != nil && adapter.initialized, "replay: invalid adapter")
	assert(adapter.gfx_frame != nil, "replay: no bound graphics frame")
	assert(output != nil, "replay: nil output")
	replay_list(adapter, adapter.gfx_frame, &output.main)
	replay_list(adapter, adapter.gfx_frame, &output.overlay)
}

replay_list :: proc(adapter: ^Adapter, frame: ^rl.Frame, list: ^ui.Paint_List) {
	assert(adapter != nil && adapter.initialized, "replay_list: invalid adapter")
	assert(
		frame != nil && rl.frame_context(frame) == adapter.gfx_context,
		"replay_list: invalid frame",
	)
	assert(list != nil && list.count >= 0, "replay_list: invalid list")
	assert(list.count <= len(list.commands), "replay_list: invalid count")
	for index in 0 ..< list.count {
		assert(index >= 0 && index < len(list.commands), "replay_list: invalid index")
		replay_command(adapter, frame, list, list.commands[index])
	}
}

@(private = "file")
replay_text_command :: proc(
	adapter: ^Adapter,
	frame: ^rl.Frame,
	list: ^ui.Paint_List,
	command: ui.Paint_Command,
) {
	assert(adapter != nil && adapter.initialized, "replay_text_command: invalid adapter")
	assert(frame != nil && list != nil, "replay_text_command: nil argument")
	text := ui.paint_text(list, command)
	font, ok := adapter_font(adapter, command.font)
	assert(ok, "replay_text_command: invalid font")
	value := strings.clone_to_cstring(text, context.temp_allocator)
	rl.draw_text(
		frame,
		font,
		value,
		vec_to_gfx(command.p0),
		command.font_size,
		command.spacing,
		color_to_gfx(command.color),
	)
}

@(private = "file")
replay_codepoint_command :: proc(adapter: ^Adapter, frame: ^rl.Frame, command: ui.Paint_Command) {
	assert(adapter != nil && adapter.initialized, "replay_codepoint_command: invalid adapter")
	assert(frame != nil, "replay_codepoint_command: nil frame")
	font, ok := adapter_font(adapter, command.font)
	assert(ok, "replay_codepoint_command: invalid font")
	rl.frame_draw_codepoint(
		frame,
		font,
		command.codepoint,
		vec_to_gfx(command.p0),
		command.font_size,
		color_to_gfx(command.color),
	)
}

@(private = "file")
replay_clip_begin_command :: proc(frame: ^rl.Frame, command: ui.Paint_Command) {
	assert(frame != nil, "replay_clip_begin_command: nil frame")
	assert(command.rect.width >= 0, "replay_clip_begin_command: negative width")
	assert(command.rect.height >= 0, "replay_clip_begin_command: negative height")
	rl.frame_scissor_begin(
		frame,
		i32(command.rect.x),
		i32(command.rect.y),
		i32(command.rect.width),
		i32(command.rect.height),
	)
}

@(private = "file")
replay_rectangle_command :: proc(frame: ^rl.Frame, command: ui.Paint_Command) {
	assert(frame != nil, "replay_rectangle_command: nil frame")
	assert(
		command.rect.width >= 0 && command.rect.height >= 0,
		"replay_rectangle_command: invalid rect",
	)
	color := color_to_gfx(command.color)
	#partial switch command.kind {
	case .Rectangle:
		rl.draw_rect(frame, rect_to_gfx(command.rect), color)
	case .Rectangle_Outline:
		rl.frame_draw_rectangle_lines(frame, rect_to_gfx(command.rect), command.thickness, color)
	case .Rectangle_Rounded:
		rl.frame_draw_rectangle_rounded(
			frame,
			rect_to_gfx(command.rect),
			command.roundness,
			command.segments,
			color,
		)
	case .Rectangle_Rounded_Outline:
		rl.frame_draw_rectangle_rounded_lines(
			frame,
			rect_to_gfx(command.rect),
			command.roundness,
			command.segments,
			command.thickness,
			color,
		)
	case .Rectangle_Gradient_V:
		rl.frame_draw_rectangle_gradient_v(
			frame,
			rect_to_gfx(command.rect),
			color,
			color_to_gfx(command.color_end),
		)
	case:
		assert(false, "replay_rectangle_command: invalid kind")
	}
}

replay_command :: proc(
	adapter: ^Adapter,
	frame: ^rl.Frame,
	list: ^ui.Paint_List,
	command: ui.Paint_Command,
) {
	assert(adapter != nil && adapter.initialized, "replay_command: invalid adapter")
	assert(frame != nil && list != nil, "replay_command: nil argument")
	color := color_to_gfx(command.color)
	switch command.kind {
	case .Rectangle,
	     .Rectangle_Outline,
	     .Rectangle_Rounded,
	     .Rectangle_Rounded_Outline,
	     .Rectangle_Gradient_V:
		replay_rectangle_command(frame, command)
	case .Line:
		rl.draw_line(
			frame,
			vec_to_gfx(command.p0),
			vec_to_gfx(command.p1),
			command.thickness,
			color,
		)
	case .Circle:
		rl.draw_circle(frame, vec_to_gfx(command.p0), command.outer_radius, color)
	case .Circle_Outline:
		rl.frame_draw_circle_lines(frame, vec_to_gfx(command.p0), command.outer_radius, color)
	case .Ring:
		rl.frame_draw_ring(
			frame,
			vec_to_gfx(command.p0),
			command.inner_radius,
			command.outer_radius,
			command.start_angle,
			command.end_angle,
			command.segments,
			color,
		)
	case .Triangle:
		rl.frame_draw_triangle(
			frame,
			vec_to_gfx(command.p0),
			vec_to_gfx(command.p1),
			vec_to_gfx(command.p2),
			color,
		)
	case .Text:
		replay_text_command(adapter, frame, list, command)
	case .Codepoint:
		replay_codepoint_command(adapter, frame, command)
	case .Clip_Begin:
		replay_clip_begin_command(frame, command)
	case .Clip_End:
		rl.frame_scissor_end(frame)
		if command.clip_restore do replay_clip_begin_command(frame, command)
	}
}

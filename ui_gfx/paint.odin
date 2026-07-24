package ui_gfx

import "core:strings"
import rl "ingot:gfx"
import "ingot:ui"

replay :: proc(adapter: ^Adapter, output: ^ui.Ui_Output) {
	assert(adapter != nil && adapter.initialized, "replay: invalid adapter")
	assert(output != nil, "replay: nil output")
	replay_list(adapter, &output.main)
	replay_list(adapter, &output.overlay)
}

replay_list :: proc(adapter: ^Adapter, list: ^ui.Paint_List) {
	assert(adapter != nil && list != nil, "replay_list: nil argument")
	for index in 0 ..< list.count {
		command := list.commands[index]
		replay_command(adapter, list, command)
	}
}

replay_command :: proc(adapter: ^Adapter, list: ^ui.Paint_List, command: ui.Paint_Command) {
	color := color_to_gfx(command.color)
	switch command.kind {
	case .Rectangle:
		rl.DrawRectangleRec(rect_to_gfx(command.rect), color)
	case .Rectangle_Outline:
		rl.DrawRectangleLinesEx(rect_to_gfx(command.rect), command.thickness, color)
	case .Rectangle_Rounded:
		rl.DrawRectangleRounded(
			rect_to_gfx(command.rect),
			command.roundness,
			command.segments,
			color,
		)
	case .Rectangle_Rounded_Outline:
		rl.DrawRectangleRoundedLinesEx(
			rect_to_gfx(command.rect),
			command.roundness,
			command.segments,
			command.thickness,
			color,
		)
	case .Rectangle_Gradient_V:
		rl.DrawRectangleGradientV(
			i32(command.rect.x),
			i32(command.rect.y),
			i32(command.rect.width),
			i32(command.rect.height),
			color,
			color_to_gfx(command.color_end),
		)
	case .Line:
		rl.DrawLineEx(vec_to_gfx(command.p0), vec_to_gfx(command.p1), command.thickness, color)
	case .Circle:
		rl.DrawCircleV(vec_to_gfx(command.p0), command.outer_radius, color)
	case .Circle_Outline:
		rl.DrawCircleLinesV(vec_to_gfx(command.p0), command.outer_radius, color)
	case .Ring:
		rl.DrawRing(
			vec_to_gfx(command.p0),
			command.inner_radius,
			command.outer_radius,
			command.start_angle,
			command.end_angle,
			command.segments,
			color,
		)
	case .Triangle:
		rl.DrawTriangle(
			vec_to_gfx(command.p0),
			vec_to_gfx(command.p1),
			vec_to_gfx(command.p2),
			color,
		)
	case .Text:
		text := ui.paint_text(list, command)
		font, ok := adapter_font(adapter, command.font)
		if ok {
			value := strings.clone_to_cstring(text, context.temp_allocator)
			rl.DrawTextEx(
				font,
				value,
				vec_to_gfx(command.p0),
				command.font_size,
				command.spacing,
				color,
			)
		}
	case .Codepoint:
		font, ok := adapter_font(adapter, command.font)
		if ok do rl.DrawTextCodepoint(font, command.codepoint, vec_to_gfx(command.p0), command.font_size, color)
	case .Clip_Begin:
		rl.BeginScissorMode(
			i32(command.rect.x),
			i32(command.rect.y),
			i32(command.rect.width),
			i32(command.rect.height),
		)
	case .Clip_End:
		rl.EndScissorMode()
	}
}

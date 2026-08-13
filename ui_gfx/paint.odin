package ui_gfx

import "core:strings"
import rl "ingot:gfx"
import "ingot:ui"

replay :: proc(adapter: ^Adapter, output: ^ui.Ui_Output) {
	assert(adapter != nil && adapter.initialized, "replay: invalid adapter")
	assert(adapter.graphics_open, "replay: no open graphics frame")
	assert(output != nil, "replay: nil output")
	replay_list(adapter, &output.main)
	replay_list_tiered(adapter, &output.overlay)
}

replay_list :: proc(adapter: ^Adapter, list: ^ui.Paint_List) {
	assert(adapter != nil && adapter.initialized, "replay_list: invalid adapter")
	assert(adapter.graphics_open, "replay_list: graphics frame not open")
	assert(list != nil && list.count >= 0, "replay_list: invalid list")
	assert(list.count <= len(list.commands), "replay_list: invalid count")
	for index in 0 ..< list.count {
		assert(index >= 0 && index < len(list.commands), "replay_list: invalid index")
		replay_command(adapter, list, list.commands[index])
	}
}

replay_list_tiered :: proc(adapter: ^Adapter, list: ^ui.Paint_List) {
	assert(adapter != nil && adapter.initialized, "replay_list_tiered: invalid adapter")
	assert(adapter.graphics_open, "replay_list_tiered: graphics frame not open")
	assert(list != nil && list.count >= 0, "replay_list_tiered: invalid list")
	assert(list.count <= len(list.commands), "replay_list_tiered: invalid count")
	order := replay_z_group_order(list)
	for order_index in 0 ..< order.count {
		group := order.groups[order_index]
		for index in 0 ..< list.count {
			command := list.commands[index]
			assert(i32(command.z_group) < list.z_group_count, "replay: invalid z group")
			if command.z_group != group do continue
			replay_command(adapter, list, command)
		}
	}
}

Replay_Z_Group_Order :: struct {
	groups: [ui.MAX_PAINT_Z_GROUPS]u8,
	count:  i32,
}

replay_z_group_order :: proc(list: ^ui.Paint_List) -> Replay_Z_Group_Order {
	assert(list != nil, "replay_z_group_order: nil list")
	assert(list.z_group_count > 0 && list.z_group_count <= ui.MAX_PAINT_Z_GROUPS)
	result := Replay_Z_Group_Order {
		count = list.z_group_count,
	}
	for index in 0 ..< result.count do result.groups[index] = u8(index)
	for index in 1 ..< result.count {
		value := result.groups[index]
		cursor := index
		for cursor > 0 && list.z_groups[result.groups[cursor - 1]] > list.z_groups[value] {
			result.groups[cursor] = result.groups[cursor - 1]
			cursor -= 1
		}
		result.groups[cursor] = value
	}
	return result
}

@(private = "file")
replay_text_command :: proc(adapter: ^Adapter, list: ^ui.Paint_List, command: ui.Paint_Command) {
	assert(adapter != nil && adapter.initialized, "replay_text_command: invalid adapter")
	assert(adapter.graphics_open && list != nil, "replay_text_command: invalid argument")
	text := ui.paint_text(list, command)
	font, ok := adapter_font(adapter, command.font)
	assert(ok, "replay_text_command: invalid font")
	value := strings.clone_to_cstring(text, context.temp_allocator)
	rl.DrawTextEx(
		font,
		value,
		vec_to_gfx(command.p0),
		command.font_size,
		command.spacing,
		color_to_gfx(command.color),
	)
}

@(private = "file")
replay_codepoint_command :: proc(adapter: ^Adapter, command: ui.Paint_Command) {
	assert(adapter != nil && adapter.initialized, "replay_codepoint_command: invalid adapter")
	assert(adapter.graphics_open, "replay_codepoint_command: graphics frame not open")
	font, ok := adapter_font(adapter, command.font)
	assert(ok, "replay_codepoint_command: invalid font")
	rl.DrawTextCodepoint(
		font,
		command.codepoint,
		vec_to_gfx(command.p0),
		command.font_size,
		color_to_gfx(command.color),
	)
}

@(private = "file")
replay_clip_begin_command :: proc(command: ui.Paint_Command) {
	assert(command.rect.width >= 0, "replay_clip_begin_command: negative width")
	assert(command.rect.height >= 0, "replay_clip_begin_command: negative height")
	rl.BeginScissorMode(
		i32(command.rect.x),
		i32(command.rect.y),
		i32(command.rect.width),
		i32(command.rect.height),
	)
}

@(private = "file")
replay_rectangle_command :: proc(command: ui.Paint_Command) {
	assert(command.rect.width >= 0 && command.rect.height >= 0, "replay rectangle: invalid rect")
	rect := rect_to_gfx(command.rect)
	color := color_to_gfx(command.color)
	#partial switch command.kind {
	case .Rectangle:
		rl.DrawRectangleRec(rect, color)
	case .Rectangle_Outline:
		rl.DrawRectangleLinesEx(rect, command.thickness, color)
	case .Rectangle_Rounded:
		rl.DrawRectangleRounded(rect, command.roundness, command.segments, color)
	case .Rectangle_Rounded_Outline:
		rl.DrawRectangleRoundedLinesEx(
			rect,
			command.roundness,
			command.segments,
			command.thickness,
			color,
		)
	case .Rectangle_Gradient_V:
		rl.DrawRectangleGradientV(
			i32(rect.x),
			i32(rect.y),
			i32(rect.width),
			i32(rect.height),
			color,
			color_to_gfx(command.color_end),
		)
	case:
		assert(false, "replay_rectangle_command: invalid kind")
	}
}

replay_command :: proc(adapter: ^Adapter, list: ^ui.Paint_List, command: ui.Paint_Command) {
	assert(adapter != nil && adapter.initialized, "replay_command: invalid adapter")
	assert(adapter.graphics_open && list != nil, "replay_command: invalid argument")
	color := color_to_gfx(command.color)
	switch command.kind {
	case .Rectangle,
	     .Rectangle_Outline,
	     .Rectangle_Rounded,
	     .Rectangle_Rounded_Outline,
	     .Rectangle_Gradient_V:
		replay_rectangle_command(command)
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
		replay_text_command(adapter, list, command)
	case .Codepoint:
		replay_codepoint_command(adapter, command)
	case .Clip_Begin:
		replay_clip_begin_command(command)
	case .Clip_End:
		rl.EndScissorMode()
		if command.clip_restore do replay_clip_begin_command(command)
	}
}

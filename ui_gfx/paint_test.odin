#+build !js
package ui_gfx

import "core:testing"
import "ingot:ui"

@(test)
replay_z_groups_sort_exact_depth_stably :: proc(t: ^testing.T) {
	list := new(ui.Paint_List)
	defer free(list)
	ui.paint_list_reset(list)
	ui.paint_list_set_z(list, ui.Z_PANEL + 75)
	high := list.current_z_group
	ui.paint_list_set_z(list, ui.Z_PANEL + 25)
	low := list.current_z_group
	ui.paint_list_set_z(list, ui.Z_PANEL + 75)
	testing.expect_value(t, list.current_z_group, high)

	order := replay_z_group_order(list)
	testing.expect_value(t, order.count, i32(3))
	testing.expect_value(t, order.groups[0], u8(0))
	testing.expect_value(t, order.groups[1], low)
	testing.expect_value(t, order.groups[2], high)
}

@(test)
replay_z_groups_keep_named_depth_order :: proc(t: ^testing.T) {
	list := new(ui.Paint_List)
	defer free(list)
	ui.paint_list_reset(list)
	ui.paint_list_set_z(list, ui.Z_TOOLTIP)
	ui.paint_list_set_z(list, ui.Z_POPUP)
	ui.paint_list_set_z(list, ui.Z_MODAL)
	ui.paint_list_set_z(list, ui.Z_PANEL)
	ui.paint_list_set_z(list, ui.Z_TOAST)
	order := replay_z_group_order(list)

	for index in 1 ..< order.count {
		previous := list.z_groups[order.groups[index - 1]]
		current := list.z_groups[order.groups[index]]
		testing.expect(t, previous <= current)
	}
}

@(test)
replay_texture_command_keeps_declaration_order_in_its_group :: proc(t: ^testing.T) {
	list := new(ui.Paint_List)
	defer free(list)
	ui.paint_list_reset(list)
	ui.paint_list_set_z(list, ui.Z_PANEL)
	group := list.current_z_group
	testing.expect(t, ui.paint_push(list, {kind = .Rectangle, rect = {0, 0, 4, 4}}))
	texture := ui.Paint_Command {
		kind    = .Texture,
		rect    = {1, 1, 2, 2},
		p1      = {2, 2},
		texture = 9,
	}
	testing.expect(t, ui.paint_push(list, texture))
	testing.expect(t, ui.paint_push(list, {kind = .Rectangle, rect = {2, 2, 4, 4}}))
	order := replay_z_group_order(list)
	testing.expect_value(t, order.groups[order.count - 1], group)
	kinds := [3]ui.Paint_Kind{.Rectangle, .Texture, .Rectangle}
	for kind, index in kinds {
		testing.expect_value(t, list.commands[index].kind, kind)
		testing.expect_value(t, list.commands[index].z_group, group)
	}
	testing.expect_value(t, ui.paint_texture_source(list.commands[1]), ui.Rect{0, 0, 2, 2})
}

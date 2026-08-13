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

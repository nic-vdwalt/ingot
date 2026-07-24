#+build !js
package ui

import "core:testing"
import ak "ingot:accesskit"

@(test)
a11y_role_mapping :: proc(t: ^testing.T) {
	// Every interactive semantic role must map to a real AccessKit role —
	// Unknown would make the widget invisible to assistive tech.
	testing.expect_value(t, a11y_role(.Button), ak.Role.Button)
	testing.expect_value(t, a11y_role(.Checkbox), ak.Role.Check_Box)
	testing.expect_value(t, a11y_role(.Radio), ak.Role.Radio_Button)
	testing.expect_value(t, a11y_role(.Slider), ak.Role.Slider)
	testing.expect_value(t, a11y_role(.Text_Input), ak.Role.Text_Input)
	testing.expect_value(t, a11y_role(.Dropdown), ak.Role.Combo_Box)
	testing.expect_value(t, a11y_role(.Menu_Item), ak.Role.Menu_Item)
	testing.expect_value(t, a11y_role(.Label), ak.Role.Label)
	testing.expect_value(t, a11y_role(.Pane), ak.Role.Pane)
	testing.expect_value(t, a11y_role(.Modal), ak.Role.Dialog)
	testing.expect_value(t, a11y_role(.None), ak.Role.Unknown)
}

@(test)
a11y_activation_expires_after_next_frame :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	frame: Ui_Frame
	slot := 0
	node_id := sem_node_id(.Button, {&slot, 1}, "", 0)

	ui_frame_begin(&frame, &runtime)
	a11y_stage_click(&runtime, node_id)
	ui_frame_end(&frame)
	testing.expect(t, runtime.pending_a11y.pending)

	ui_frame_begin(&frame, &runtime)
	testing.expect(t, !a11y_take_click(&runtime, node_id + 1))
	testing.expect(t, a11y_take_click(&runtime, node_id))
	testing.expect(t, !runtime.pending_a11y.pending)
	ui_frame_end(&frame)

	ui_frame_begin(&frame, &runtime)
	a11y_stage_click(&runtime, node_id)
	ui_frame_end(&frame)
	ui_frame_begin(&frame, &runtime)
	ui_frame_end(&frame)
	testing.expect(t, !runtime.pending_a11y.pending)

	ui_frame_begin(&frame, &runtime)
	testing.expect(t, !a11y_take_click(&runtime, node_id))
	ui_frame_end(&frame)
}

@(test)
a11y_rejects_missing_and_routes_live_targets :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	sem_enable(&runtime, true)
	frame: Ui_Frame
	slot := 0

	ui_frame_begin(&frame, &runtime)
	node := semantic_push(&frame, .Button, {0, 0, 10, 10}, "Open", focus = {&slot, 1})
	testing.expect(t, node != nil)
	a11y_apply_action(&frame, {.Focus, node.id})
	testing.expect_value(t, slot, 1)
	a11y_apply_action(&frame, {.Click, node.id})
	testing.expect(t, runtime.pending_a11y.pending)
	ui_frame_end(&frame)

	ui_frame_begin(&frame, &runtime)
	a11y_apply_action(&frame, {.Click, node.id + 1})
	testing.expect_value(t, runtime.pending_a11y.node_id, node.id)
	ui_frame_end(&frame)
}

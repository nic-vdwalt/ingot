#+build !js
package ui

import "core:testing"

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

@(test)
a11y_adjustment_actions_require_writable_sliders :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	sem_enable(&runtime, true)
	frame: Ui_Frame
	focus := 0

	ui_frame_begin(&frame, &runtime)
	slider := semantic_push(
		&frame,
		.Slider,
		{0, 0, 100, 20},
		"Volume",
		focus = {&focus, 1},
		value = 0.5,
		lo = 0,
		hi = 1,
	)
	button := semantic_push(&frame, .Button, {0, 24, 100, 20}, "Apply")
	disabled := semantic_push(
		&frame,
		.Slider,
		{0, 48, 100, 20},
		"Disabled",
		{.Disabled},
		field_id = "disabled-slider",
		value = 0.5,
		lo = 0,
		hi = 1,
	)
	testing.expect(t, slider != nil && button != nil && disabled != nil)
	a11y_apply_action(&frame, {.Increment, button.id})
	testing.expect(t, !runtime.pending_a11y.pending)
	a11y_apply_action(&frame, {.Increment, disabled.id})
	testing.expect(t, !runtime.pending_a11y.pending)
	a11y_apply_action(&frame, {.Increment, slider.id})
	testing.expect(t, runtime.pending_a11y.pending)
	ui_frame_end(&frame)

	ui_frame_begin(&frame, &runtime)
	testing.expect(t, !a11y_take_action(&runtime, slider.id, .Decrement))
	testing.expect(t, a11y_take_action(&runtime, slider.id, .Increment))
	testing.expect(t, !a11y_take_action(&runtime, slider.id, .Increment))
	ui_frame_end(&frame)
}

#+build !js
package ui

import "core:testing"

@(test)
paint_telemetry_counts_successful_writes_and_rejected_command_text :: proc(t: ^testing.T) {
	list := new(Paint_List)
	defer free(list)
	paint_push(list, {kind = .Rectangle})
	paint_push_text(list, {kind = .Text}, "abc")
	when UI_TELEMETRY_ENABLED {
		testing.expect_value(t, list.command_append_count, u64(2))
		testing.expect_value(t, list.text_append_count, u64(1))
		testing.expect_value(t, list.text_bytes_copied, u64(3))
		testing.expect_value(t, list.command_growth_count, u64(0))
		testing.expect_value(t, list.text_growth_count, u64(0))
	}
	list.count = PAINT_COMMAND_CAP
	paint_push_text(list, {kind = .Text}, "lost")
	when UI_TELEMETRY_ENABLED {
		testing.expect_value(t, list.command_append_count, u64(2))
		testing.expect_value(t, list.text_append_count, u64(2))
		testing.expect_value(t, list.text_bytes_copied, u64(7))
	}
	paint_list_reset(list)
	when UI_TELEMETRY_ENABLED {
		testing.expect_value(t, list.command_append_count, u64(0))
		testing.expect_value(t, list.text_append_count, u64(0))
		testing.expect_value(t, list.text_bytes_copied, u64(0))
	}
}

@(test)
paint_clip_nested_intersection_and_restore :: proc(t: ^testing.T) {
	list := new(Paint_List)
	defer free(list)
	paint_clip_begin(list, {10, 20, 100, 80})
	paint_clip_begin(list, {50, 0, 100, 50})
	paint_clip_end(list)
	paint_clip_end(list)

	testing.expect_value(t, list.count, 4)
	testing.expect_value(t, list.commands[0].rect, Rect{10, 20, 100, 80})
	testing.expect_value(t, list.commands[1].rect, Rect{50, 20, 60, 30})
	testing.expect(t, list.commands[2].clip_restore)
	testing.expect_value(t, list.commands[2].rect, Rect{10, 20, 100, 80})
	testing.expect(t, !list.commands[3].clip_restore)
	testing.expect_value(t, list.clip_count, 0)
}

@(test)
paint_clip_disjoint_intersection_is_empty :: proc(t: ^testing.T) {
	list := new(Paint_List)
	defer free(list)
	paint_clip_begin(list, {0, 0, 10, 10})
	paint_clip_begin(list, {20, 30, 5, 5})

	testing.expect_value(t, list.commands[1].rect, Rect{20, 30, 0, 0})
	testing.expect_value(t, list.clip_stack[1], Rect{20, 30, 0, 0})
	paint_clip_end(list)
	paint_clip_end(list)
}

@(test)
paint_clip_stack_reaches_static_capacity :: proc(t: ^testing.T) {
	list := new(Paint_List)
	defer free(list)
	for index in 0 ..< PAINT_CLIP_CAP {
		paint_clip_begin(list, {f32(index), f32(index), 100, 100})
	}
	testing.expect_value(t, list.clip_count, PAINT_CLIP_CAP)
	testing.expect_value(t, list.count, PAINT_CLIP_CAP)
	for _ in 0 ..< PAINT_CLIP_CAP do paint_clip_end(list)
	testing.expect_value(t, list.clip_count, 0)
	testing.expect_value(t, list.count, PAINT_CLIP_CAP * 2)
}

@(test)
paint_clip_balances_when_command_buffer_saturates :: proc(t: ^testing.T) {
	list := new(Paint_List)
	defer free(list)
	// Fill the command buffer so every subsequent push is dropped. The clip
	// stack must still unwind, otherwise a frame that overflows can never
	// balance its clips again.
	for _ in 0 ..< PAINT_COMMAND_CAP {
		paint_push(list, {kind = .Rectangle})
	}
	testing.expect_value(t, list.count, PAINT_COMMAND_CAP)

	paint_clip_begin(list, {0, 0, 10, 10})
	paint_clip_begin(list, {2, 2, 4, 4})
	testing.expect_value(t, list.clip_count, 2)
	// The intersection is still tracked even though nothing was recorded.
	testing.expect_value(t, list.clip_stack[1], Rect{2, 2, 4, 4})

	paint_clip_end(list)
	paint_clip_end(list)
	testing.expect_value(t, list.clip_count, 0)
	// Only the two begins are counted as dropped; their ends are skipped
	// outright so the recorded stream never carries an unpaired Clip_End.
	testing.expect_value(t, list.dropped_commands, 2)
}

@(test)
paint_clip_end_is_skipped_when_its_begin_was_dropped :: proc(t: ^testing.T) {
	list := new(Paint_List)
	defer free(list)
	// An outer clip that fits, then saturation, then an inner clip that is
	// dropped. The replayed stream must not contain an unpaired Clip_End.
	paint_clip_begin(list, {0, 0, 100, 100})
	for list.count < PAINT_COMMAND_CAP {
		paint_push(list, {kind = .Rectangle})
	}
	paint_clip_begin(list, {10, 10, 20, 20})
	paint_clip_end(list)
	testing.expect_value(t, list.clip_count, 1)
	testing.expect_value(t, list.count, PAINT_COMMAND_CAP)

	begins, ends: int
	for index in 0 ..< list.count {
		#partial switch list.commands[index].kind {
		case .Clip_Begin:
			begins += 1
		case .Clip_End:
			ends += 1
		}
	}
	testing.expect_value(t, begins, 1)
	testing.expect_value(t, ends, 0)
}

@(test)
paint_clip_main_overlay_and_pane_coordinates_are_isolated :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	frame: Ui_Frame
	output := new(Ui_Output)
	defer free(output)
	frame.output = output
	ui_frame_begin(&frame, &runtime)
	ui_frame_pane_push(&frame, {40, 60})
	begin_pane_scissor(&frame, 5, 10, 30, 20)
	end_scissor_mode(&frame)
	ui_frame_pane_pop(&frame)
	paint_clip_begin(&output.overlay, {1, 2, 3, 4})
	paint_clip_end(&output.overlay)
	ui_frame_end(&frame)

	testing.expect_value(t, output.main.commands[0].rect, Rect{45, 70, 30, 20})
	testing.expect_value(t, output.overlay.commands[0].rect, Rect{1, 2, 3, 4})
	testing.expect_value(t, output.main.clip_count, 0)
	testing.expect_value(t, output.overlay.clip_count, 0)
}

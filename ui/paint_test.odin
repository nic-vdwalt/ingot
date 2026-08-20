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
	testing.expect_value(t, list.text_len, len("abc"))
	when UI_TELEMETRY_ENABLED {
		testing.expect_value(t, list.command_append_count, u64(2))
		testing.expect_value(t, list.text_append_count, u64(1))
		testing.expect_value(t, list.text_bytes_copied, u64(3))
	}
	paint_list_reset(list)
	when UI_TELEMETRY_ENABLED {
		testing.expect_value(t, list.command_append_count, u64(0))
		testing.expect_value(t, list.text_append_count, u64(0))
		testing.expect_value(t, list.text_bytes_copied, u64(0))
	}
}

@(test)
paint_specialized_fields_match_generic_commands_and_clear_slots :: proc(t: ^testing.T) {
	generic := new(Paint_List)
	specialized := new(Paint_List)
	defer free(generic)
	defer free(specialized)
	stale := Paint_Command {
		kind         = .Ring,
		p0           = {99, 98},
		p1           = {97, 96},
		thickness    = 95,
		codepoint    = 'Z',
		clip_restore = true,
	}
	generic.commands[0] = stale
	specialized.commands[0] = stale
	generic.current_tier = 3
	generic.current_z_group = 4
	specialized.current_tier = 3
	specialized.current_z_group = 4
	rect := Rect{1, 2, 3, 4}
	color := Color{5, 6, 7, 8}
	paint_push(generic, {kind = .Rectangle, rect = rect, color = color, tier = 9, z_group = 9})
	paint_push_rectangle(specialized, rect, color)
	testing.expect_value(t, specialized.commands[0], generic.commands[0])
	paint_push(
		generic,
		{kind = .Rectangle_Rounded, rect = rect, roundness = 0.25, segments = 6, color = color},
	)
	paint_push_rectangle_rounded(specialized, rect, 0.25, 6, color)
	testing.expect_value(t, specialized.commands[1], generic.commands[1])
}

@(test)
paint_specialized_text_matches_generic_storage_and_telemetry :: proc(t: ^testing.T) {
	generic := new(Paint_List)
	specialized := new(Paint_List)
	defer free(generic)
	defer free(specialized)
	generic.current_tier = 2
	generic.current_z_group = 3
	specialized.current_tier = 2
	specialized.current_z_group = 3
	command := Paint_Command {
		kind      = .Text,
		p0        = {4, 5},
		color     = {6, 7, 8, 9},
		font      = 10,
		font_size = 11,
		spacing   = 12,
	}
	paint_push_text(generic, command, "fields")
	paint_push_text_fields(specialized, "fields", {4, 5}, {6, 7, 8, 9}, 10, 11, 12)
	testing.expect_value(t, specialized.commands[0], generic.commands[0])
	testing.expect_value(t, paint_text(specialized, specialized.commands[0]), "fields")
	testing.expect_value(t, specialized.text_len, generic.text_len)
	when UI_TELEMETRY_ENABLED {
		testing.expect_value(t, specialized.command_append_count, generic.command_append_count)
		testing.expect_value(t, specialized.text_append_count, generic.text_append_count)
		testing.expect_value(t, specialized.text_bytes_copied, generic.text_bytes_copied)
	}
}

@(test)
paint_specialized_rejection_preserves_reservations_sink_and_text :: proc(t: ^testing.T) {
	list := new(Paint_List)
	defer free(list)
	paint_clip_begin(list, {0, 0, 20, 20})
	list.count = PAINT_COMMAND_CAP - list.clip_end_reserved
	list.current_tier = 4
	list.current_z_group = 5
	streamed := Paint_Command{}
	sink := proc(list: ^Paint_List, command: Paint_Command, userdata: rawptr) {
		assert(list.count == PAINT_COMMAND_CAP - list.clip_end_reserved)
		value := cast(^Paint_Command)userdata
		value^ = command
	}
	paint_list_set_sink(list, sink, &streamed)
	retained := paint_push_rectangle(list, {1, 2, 3, 4}, {5, 6, 7, 8})
	testing.expect(t, !retained)
	testing.expect_value(t, streamed.tier, u8(4))
	testing.expect_value(t, streamed.z_group, u8(5))
	testing.expect_value(t, list.dropped_commands, 1)
	retained = paint_push_text_fields(list, "sink", {9, 10}, {11, 12, 13, 14}, 2, 16)
	testing.expect(t, !retained)
	testing.expect_value(t, streamed.text_length, len("sink"))
	testing.expect_value(t, list.text_len, 0)
	testing.expect_value(t, list.dropped_commands, 2)
	paint_list_set_sink(list, nil, nil)
	list.count = 1
	list.current_tier = 0
	list.current_z_group = 0
	paint_clip_end(list)
	testing.expect_value(t, list.clip_end_reserved, 0)
}

@(test)
paint_specialized_text_overflow_does_not_append_or_stream :: proc(t: ^testing.T) {
	list := new(Paint_List)
	defer free(list)
	list.text_len = PAINT_TEXT_CAP
	streamed := 0
	sink := proc(list: ^Paint_List, command: Paint_Command, userdata: rawptr) {
		value := cast(^int)userdata
		value^ += 1
	}
	paint_list_set_sink(list, sink, &streamed)
	retained := paint_push_text_fields(list, "x", {1, 2}, {3, 4, 5, 6}, 7, 8)
	testing.expect(t, !retained)
	testing.expect_value(t, list.count, 0)
	testing.expect_value(t, list.text_len, PAINT_TEXT_CAP)
	testing.expect_value(t, list.dropped_text_bytes, 1)
	testing.expect_value(t, list.dropped_commands, 0)
	testing.expect_value(t, streamed, 0)
}

@(test)
paint_specialized_frame_paths_translate_once_and_preserve_order :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	frame: Ui_Frame
	output := new(Ui_Output)
	defer free(output)
	frame.output = output
	ui_frame_begin(&frame, &runtime)
	ui_frame_pane_push(&frame, {10, 20})
	draw_rectangle(&frame, 1, 2, 3, 4, {1, 2, 3, 4})
	draw_rectangle_rec(&frame, {5, 6, 7, 8}, {5, 6, 7, 8})
	draw_rectangle_rounded(&frame, {9, 10, 11, 12}, 0.5, 6, {9, 10, 11, 12})
	draw_text_command(&frame, "order", 13, 14, 15, {13, 14, 15, 16}, 2)
	ui_frame_pane_pop(&frame)
	ui_frame_end(&frame)
	testing.expect_value(t, output.main.count, 4)
	testing.expect_value(t, output.main.commands[0].rect, Rect{11, 22, 3, 4})
	testing.expect_value(t, output.main.commands[1].rect, Rect{15, 26, 7, 8})
	testing.expect_value(t, output.main.commands[2].rect, Rect{19, 30, 11, 12})
	testing.expect_value(t, output.main.commands[3].p0, Vec2{23, 34})
	testing.expect_value(t, output.main.commands[3].kind, Paint_Kind.Text)
	testing.expect_value(t, paint_text(&output.main, output.main.commands[3]), "order")
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
paint_clip_nested_negative_extent_is_empty_and_balanced :: proc(t: ^testing.T) {
	list := new(Paint_List)
	defer free(list)
	paint_clip_begin(list, {0, 0, 10, 10})
	paint_clip_begin(list, {4, 5, -2, -3})
	testing.expect_value(t, list.clip_stack[1], Rect{4, 5, 0, 0})
	paint_clip_end(list)
	paint_clip_end(list)
	testing.expect_value(t, list.clip_count, 0)
	testing.expect_value(t, list.count, 4)
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
paint_clip_reserves_end_when_body_saturates :: proc(t: ^testing.T) {
	list := new(Paint_List)
	defer free(list)
	paint_clip_begin(list, {0, 0, 100, 100})
	for _ in 0 ..< PAINT_COMMAND_CAP do paint_push(list, {kind = .Rectangle})
	testing.expect_value(t, list.count, PAINT_COMMAND_CAP - 1)
	testing.expect_value(t, list.clip_end_reserved, 1)

	paint_clip_begin(list, {10, 10, 20, 20})
	paint_clip_end(list)
	testing.expect_value(t, list.clip_count, 1)
	paint_clip_end(list)
	testing.expect_value(t, list.count, PAINT_COMMAND_CAP)
	testing.expect_value(t, list.clip_end_reserved, 0)

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
	testing.expect_value(t, ends, 1)
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

@(test)
paint_peaks_are_finalized_at_frame_end_for_both_channels :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	frame: Ui_Frame
	output := new(Ui_Output)
	defer free(output)
	frame.output = output
	ui_frame_begin(&frame, &runtime)
	paint_push(&output.main, {kind = .Rectangle})
	paint_push_text(&output.overlay, {kind = .Text}, "overlay")
	ui_frame_end(&frame)
	testing.expect_value(t, output.main.peak_count, 1)
	testing.expect_value(t, output.main.peak_text_len, 0)
	testing.expect_value(t, output.overlay.peak_count, 1)
	testing.expect_value(t, output.overlay.peak_text_len, len("overlay"))
}

@(test)
codepoint_scope_emits_cumulative_screen_coordinates :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	frame: Ui_Frame
	output := new(Ui_Output)
	defer free(output)
	frame.output = output
	ui_frame_begin(&frame, &runtime)
	ui_frame_pane_push(&frame, {40, 60})
	ui_frame_pane_push(&frame, {5, -10})
	draw_codepoint_command(&frame, 'A', 3, 7, 16, {255, 255, 255, 255}, 1)
	ui_frame_pane_pop(&frame)
	ui_frame_pane_pop(&frame)
	ui_frame_end(&frame)

	testing.expect_value(t, output.main.count, 1)
	testing.expect_value(t, output.main.commands[0].kind, Paint_Kind.Codepoint)
	testing.expect_value(t, output.main.commands[0].p0, Vector2{48, 57})
	testing.expect_value(t, output.main.commands[0].font, Font_Id(1))
	testing.expect_value(t, output.main.commands[0].codepoint, rune('A'))
}

@(test)
target_codepoint_scope_preserves_target_coordinates :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	frame: Ui_Frame
	output := new(Ui_Output)
	defer free(output)
	frame.output = output
	ui_frame_begin(&frame, &runtime)
	ui_frame_pane_push(&frame, {40, 60})
	draw_target_codepoint_command(&frame, 'A', 3, 7, 16, {255, 255, 255, 255}, 1)
	ui_frame_pane_pop(&frame)
	ui_frame_end(&frame)

	testing.expect_value(t, output.main.count, 1)
	testing.expect_value(t, output.main.commands[0].kind, Paint_Kind.Codepoint)
	testing.expect_value(t, output.main.commands[0].p0, Vector2{3, 7})
}

@(test)
canvas_scope_emits_screen_space_paint_and_balanced_clip :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	frame: Ui_Frame
	output := new(Ui_Output)
	defer free(output)
	frame.output = output
	ui_frame_begin(&frame, &runtime)

	canvas_begin(&frame, {40, 60, 300, 200}, {0, -25})
	canvas_clear(&frame, {0, 0, 300, 200}, {10, 20, 30, 255})
	testing.expect_value(t, frame_pane_origin(&frame), Vector2{40, 35})
	canvas_end(&frame)
	testing.expect_value(t, frame_pane_origin(&frame), Vector2{})
	ui_frame_end(&frame)

	testing.expect_value(t, output.main.count, 3)
	testing.expect_value(t, output.main.commands[0].kind, Paint_Kind.Clip_Begin)
	testing.expect_value(t, output.main.commands[0].rect, Rect{40, 60, 300, 200})
	testing.expect_value(t, output.main.commands[1].kind, Paint_Kind.Rectangle)
	testing.expect_value(t, output.main.commands[1].rect, Rect{40, 35, 300, 200})
	testing.expect_value(t, output.main.commands[2].kind, Paint_Kind.Clip_End)
	testing.expect_value(t, output.main.clip_count, 0)
}

@(test)
nested_canvas_uses_cumulative_origin_and_parent_clip :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	frame: Ui_Frame
	output := new(Ui_Output)
	defer free(output)
	frame.output = output
	ui_frame_begin(&frame, &runtime)

	canvas_begin(&frame, {100, 50, 200, 120}, {0, -10})
	canvas_begin(&frame, {20, 30, 100, 80}, {-5, 0})
	draw_line_ex(&frame, {1, 2}, {3, 4}, 1, {255, 255, 255, 255})
	testing.expect_value(t, frame_pane_origin(&frame), Vector2{115, 70})
	testing.expect_value(t, frame_to_local(&frame, {116, 72}), Vector2{1, 2})
	canvas_end(&frame)
	canvas_end(&frame)
	ui_frame_end(&frame)

	testing.expect_value(t, output.main.commands[0].rect, Rect{100, 50, 200, 120})
	testing.expect_value(t, output.main.commands[1].rect, Rect{120, 70, 100, 80})
	testing.expect_value(t, output.main.commands[2].p0, Vector2{116, 72})
	testing.expect_value(t, output.main.commands[2].p1, Vector2{118, 74})
	testing.expect_value(t, output.main.commands[3].kind, Paint_Kind.Clip_End)
	testing.expect_value(t, output.main.commands[4].kind, Paint_Kind.Clip_End)
	testing.expect_value(t, output.main.clip_count, 0)
	testing.expect_value(t, output.main.clip_end_reserved, 0)
}

@(test)
paint_clip_with_one_free_slot_drops_entire_scope :: proc(t: ^testing.T) {
	list := new(Paint_List)
	defer free(list)
	list.count = PAINT_COMMAND_CAP - 1
	paint_clip_begin(list, {0, 0, 10, 10})
	testing.expect_value(t, list.count, PAINT_COMMAND_CAP - 1)
	testing.expect_value(t, list.clip_count, 1)
	testing.expect_value(t, list.clip_end_reserved, 0)
	paint_clip_end(list)
	testing.expect_value(t, list.count, PAINT_COMMAND_CAP - 1)
	testing.expect_value(t, list.clip_count, 0)
}

@(test)
paint_clip_sink_observes_balanced_saturated_stream :: proc(t: ^testing.T) {
	list := new(Paint_List)
	defer free(list)
	balance: int
	sink := proc(list: ^Paint_List, command: Paint_Command, userdata: rawptr) {
		value := cast(^int)userdata
		if command.kind == .Clip_Begin do value^ += 1
		if command.kind == .Clip_End do value^ -= 1
	}
	paint_list_set_sink(list, sink, &balance)
	paint_clip_begin(list, {0, 0, 20, 20})
	for _ in 0 ..< PAINT_COMMAND_CAP do paint_push(list, {kind = .Rectangle})
	paint_clip_end(list)
	testing.expect_value(t, balance, 0)
	testing.expect_value(t, list.clip_end_reserved, 0)
}

@(test)
paint_sink_streams_commands_after_recording_saturates :: proc(t: ^testing.T) {
	list := new(Paint_List)
	defer free(list)
	streamed: int
	sink := proc(list: ^Paint_List, command: Paint_Command, userdata: rawptr) {
		assert(list != nil)
		assert(command.kind == .Rectangle)
		value := cast(^int)userdata
		value^ += 1
	}
	paint_list_set_sink(list, sink, &streamed)
	for _ in 0 ..< PAINT_COMMAND_CAP + 3 do paint_push(list, {kind = .Rectangle})
	testing.expect_value(t, streamed, PAINT_COMMAND_CAP + 3)
	testing.expect_value(t, list.count, PAINT_COMMAND_CAP)
	testing.expect_value(t, list.dropped_commands, 3)
}

@(test)
paint_sink_streams_text_after_command_recording_saturates :: proc(t: ^testing.T) {
	list := new(Paint_List)
	defer free(list)
	streamed_text := ""
	sink := proc(list: ^Paint_List, command: Paint_Command, userdata: rawptr) {
		assert(list != nil)
		assert(command.kind == .Text)
		value := cast(^string)userdata
		value^ = paint_text(list, command)
	}
	for _ in 0 ..< PAINT_COMMAND_CAP do paint_push(list, {kind = .Rectangle})
	paint_list_set_sink(list, sink, &streamed_text)
	retained := paint_push_text(list, {kind = .Text}, "include")
	testing.expect(t, !retained)
	testing.expect_value(t, streamed_text, "include")
	testing.expect_value(t, list.count, PAINT_COMMAND_CAP)
	testing.expect_value(t, list.text_len, 0)
	testing.expect_value(t, list.dropped_commands, 1)
}

@(test)
paint_sink_balances_clip_started_after_recording_saturates :: proc(t: ^testing.T) {
	list := new(Paint_List)
	defer free(list)
	balance: int
	sink := proc(list: ^Paint_List, command: Paint_Command, userdata: rawptr) {
		assert(list != nil)
		assert(command.kind == .Clip_Begin || command.kind == .Clip_End)
		value := cast(^int)userdata
		if command.kind == .Clip_Begin do value^ += 1
		if command.kind == .Clip_End do value^ -= 1
	}
	for _ in 0 ..< PAINT_COMMAND_CAP do paint_push(list, {kind = .Rectangle})
	paint_list_set_sink(list, sink, &balance)
	paint_clip_begin(list, {0, 0, 20, 20})
	testing.expect_value(t, balance, 1)
	paint_clip_end(list)
	testing.expect_value(t, balance, 0)
	testing.expect_value(t, list.count, PAINT_COMMAND_CAP)
	testing.expect_value(t, list.dropped_commands, 1)
	testing.expect_value(t, list.clip_count, 0)
	testing.expect_value(t, list.clip_end_reserved, 0)
}

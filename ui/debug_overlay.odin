package ui

DEBUG_OVERLAY_MAX_ROWS :: 24

Renderer_Diagnostics :: struct {
	flush_count:       u64,
	vertices_uploaded: u64,
	bytes_uploaded:    u64,
	buffer_creations:  u64,
	buffer_growths:    u64,
	pipeline_switches: u64,
	render_passes:     u64,
	peak_arena_bytes:  u64,
}

@(private = "file")
Debug_Overlay_Cell :: struct {
	key, value: string,
}

@(private = "file")
debug_overlay_push :: proc(rows: []Debug_Overlay_Cell, count: ^int, key, value: string) {
	assert(count != nil, "debug_overlay_push: nil count")
	assert(count^ < len(rows), "draw_debug_overlay: row overflow")
	rows[count^] = {key, value}
	count^ += 1
}

// Joins counters as "a / b / c". Counters are formatted with Label_Text, not
// core:fmt, because this runs every frame while the overlay is open and hot
// fmt procedures crash Safari's optimizing WASM tier (see ui/label_text.odin).
@(private = "file")
debug_overlay_counts :: proc(values: []i64, suffix: string = "") -> string {
	assert(len(values) > 0 && len(values) <= 4, "debug_overlay_counts: bad value count")
	label_text: Label_Text
	for value, index in values {
		if index > 0 do label_text_string(&label_text, " / ")
		label_text_int(&label_text, value)
	}
	label_text_string(&label_text, suffix)
	return label_text_temp(&label_text)
}

// Formats "a (b noun)", e.g. "12 (3 evicted)".
@(private = "file")
debug_overlay_count_note :: proc(value, note_value: i64, note: string) -> string {
	assert(len(note) > 0, "debug_overlay_count_note: empty note")
	label_text: Label_Text
	label_text_int(&label_text, value)
	label_text_string(&label_text, " (")
	label_text_int(&label_text, note_value)
	label_text_byte(&label_text, ' ')
	label_text_string(&label_text, note)
	label_text_byte(&label_text, ')')
	return label_text_temp(&label_text)
}

@(private = "file")
debug_overlay_frame_time :: proc(frame_time: f32) -> string {
	assert(frame_time >= 0, "debug_overlay_frame_time: negative frame time")
	label_text: Label_Text
	label_text_float(&label_text, f64(frame_time * 1000), 2)
	label_text_string(&label_text, " ms")
	return label_text_temp(&label_text)
}

@(private = "file")
debug_overlay_rows :: proc(
	frame: ^Ui_Frame,
	stats: Renderer_Diagnostics,
	rows: []Debug_Overlay_Cell,
) -> int {
	assert(frame != nil, "debug_overlay_rows: nil frame")
	count := 0
	input := frame_input(frame)
	debug_overlay_push(rows, &count, "fps", debug_overlay_counts({i64(input.fps)}))
	debug_overlay_push(rows, &count, "frame", debug_overlay_frame_time(input.frame_time))
	debug_overlay_push(rows, &count, "flushes", debug_overlay_counts({i64(stats.flush_count)}))
	vertices := debug_overlay_counts({i64(stats.vertices_uploaded)})
	debug_overlay_push(rows, &count, "vertices", vertices)
	uploaded := debug_overlay_counts({i64(stats.bytes_uploaded / 1024)}, " KB")
	debug_overlay_push(rows, &count, "uploaded", uploaded)
	buffers := debug_overlay_counts({i64(stats.buffer_creations), i64(stats.buffer_growths)})
	debug_overlay_push(rows, &count, "buffers new/grown", buffers)
	switches := debug_overlay_counts({i64(stats.pipeline_switches)})
	debug_overlay_push(rows, &count, "pipeline switches", switches)
	passes := debug_overlay_counts({i64(stats.render_passes)})
	debug_overlay_push(rows, &count, "render passes", passes)
	arena := debug_overlay_counts({i64(stats.peak_arena_bytes / 1024)}, " KB")
	debug_overlay_push(rows, &count, "peak geom arena", arena)
	entries, evictions := measure_cache_stats_with(ui_frame_text(frame))
	cache := debug_overlay_count_note(i64(entries), i64(evictions), "evicted")
	debug_overlay_push(rows, &count, "measure cache", cache)
	overlay := debug_overlay_count_note(
		i64(overlay_cmd_count(frame)),
		i64(overlay_dropped(frame)),
		"dropped",
	)
	debug_overlay_push(rows, &count, "overlay cmds", overlay)
	claims := debug_overlay_counts({i64(route_claim_count(frame))})
	debug_overlay_push(rows, &count, "route claims", claims)
	diagnostics := ui_frame_diagnostics(frame)
	drops := debug_overlay_counts(
		{i64(diagnostics.input_characters_dropped), i64(diagnostics.degenerate_widgets_dropped)},
	)
	debug_overlay_push(rows, &count, "input / geometry drops", drops)
	semantic := debug_overlay_counts(
		{
			i64(diagnostics.semantic_nodes_dropped),
			i64(diagnostics.semantic_focus_dropped),
			i64(diagnostics.semantic_actions_dropped),
		},
	)
	debug_overlay_push(rows, &count, "semantic drops", semantic)
	debug_overlay_diagnostic_rows(rows, &count, diagnostics)
	return count
}

@(private = "file")
debug_overlay_diagnostic_rows :: proc(
	rows: []Debug_Overlay_Cell,
	count: ^int,
	diagnostics: Ui_Frame_Diagnostics,
) {
	assert(count != nil, "debug_overlay_diagnostic_rows: nil count")
	ids := debug_overlay_counts(
		{i64(diagnostics.semantic_id_collisions), i64(diagnostics.semantic_text_truncations)},
	)
	debug_overlay_push(rows, count, "semantic ids / text", ids)
	paint := debug_overlay_counts(
		{i64(diagnostics.main_commands_dropped), i64(diagnostics.overlay_commands_dropped)},
	)
	debug_overlay_push(rows, count, "paint cmd drops", paint)
	text_drops := debug_overlay_counts(
		{
			i64(diagnostics.main_text_bytes_dropped),
			i64(diagnostics.overlay_text_bytes_dropped),
			i64(diagnostics.platform_controls_dropped),
		},
	)
	debug_overlay_push(rows, count, "paint text / controls", text_drops)
}

draw_debug_overlay :: proc(frame: ^Ui_Frame, x, y: i32, stats: Renderer_Diagnostics = {}) -> i32 {
	assert(frame != nil && frame.open, "draw_debug_overlay: invalid frame")
	assert(x >= 0 && y >= 0, "draw_debug_overlay: negative origin")
	style := ui_frame_theme(frame)
	label_h := text_role_size(frame, .Label)
	row_h := label_h + ui_frame_sc(frame, 4)
	pad := ui_frame_sc(frame, 8)
	width := ui_frame_sc(frame, 280)
	rows: [DEBUG_OVERLAY_MAX_ROWS]Debug_Overlay_Cell
	count := debug_overlay_rows(frame, stats, rows[:])
	height := i32(count) * row_h + pad * 2 + label_h + ui_frame_sc(frame, 6)
	panel := Rectangle{f32(x), f32(y), f32(width), f32(height)}
	draw_rectangle_rec(
		frame,
		panel,
		Color{style.bg_popup.r, style.bg_popup.g, style.bg_popup.b, 235},
	)
	draw_rectangle_lines_ex(frame, panel, ui_frame_scf(frame, 1), style.border_color)
	text_y := y + pad
	text(frame, "DEBUG", x + pad, text_y, .Label, .Label)
	text_y += label_h + ui_frame_sc(frame, 6)
	for index in 0 ..< count {
		kv_row_at(
			frame,
			{x + pad, text_y, width - pad * 2, row_h},
			rows[index].key,
			rows[index].value,
			style.fg_secondary,
			style.fg_primary,
		)
		text_y += row_h
	}
	return height
}

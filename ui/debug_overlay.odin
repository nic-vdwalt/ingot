package ui

import "core:fmt"

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
	assert(count^ < len(rows), "draw_debug_overlay: row overflow")
	rows[count^] = {key, value}
	count^ += 1
}

@(private = "file")
debug_overlay_rows :: proc(
	frame: ^Ui_Frame,
	stats: Renderer_Diagnostics,
	rows: []Debug_Overlay_Cell,
) -> int {
	count := 0
	debug_overlay_push(rows, &count, "fps", fmt.tprintf("%d", frame_input(frame).fps))
	debug_overlay_push(
		rows,
		&count,
		"frame",
		fmt.tprintf("%.2f ms", frame_input(frame).frame_time * 1000),
	)
	debug_overlay_push(rows, &count, "flushes", fmt.tprintf("%d", stats.flush_count))
	debug_overlay_push(rows, &count, "vertices", fmt.tprintf("%d", stats.vertices_uploaded))
	debug_overlay_push(rows, &count, "uploaded", fmt.tprintf("%d KB", stats.bytes_uploaded / 1024))
	debug_overlay_push(
		rows,
		&count,
		"buffers new/grown",
		fmt.tprintf("%d / %d", stats.buffer_creations, stats.buffer_growths),
	)
	debug_overlay_push(
		rows,
		&count,
		"pipeline switches",
		fmt.tprintf("%d", stats.pipeline_switches),
	)
	debug_overlay_push(rows, &count, "render passes", fmt.tprintf("%d", stats.render_passes))
	debug_overlay_push(
		rows,
		&count,
		"peak geom arena",
		fmt.tprintf("%d KB", stats.peak_arena_bytes / 1024),
	)
	entries, evictions := measure_cache_stats_with(ui_frame_text(frame))
	debug_overlay_push(
		rows,
		&count,
		"measure cache",
		fmt.tprintf("%d (%d evicted)", entries, evictions),
	)
	debug_overlay_push(
		rows,
		&count,
		"overlay cmds",
		fmt.tprintf("%d (%d dropped)", overlay_cmd_count(frame), overlay_dropped(frame)),
	)
	debug_overlay_push(rows, &count, "route claims", fmt.tprintf("%d", route_claim_count(frame)))
	diagnostics := ui_frame_diagnostics(frame)
	debug_overlay_push(
		rows,
		&count,
		"input / geometry drops",
		fmt.tprintf(
			"%d / %d",
			diagnostics.input_characters_dropped,
			diagnostics.degenerate_widgets_dropped,
		),
	)
	debug_overlay_push(
		rows,
		&count,
		"semantic drops",
		fmt.tprintf(
			"%d / %d / %d",
			diagnostics.semantic_nodes_dropped,
			diagnostics.semantic_focus_dropped,
			diagnostics.semantic_actions_dropped,
		),
	)
	debug_overlay_diagnostic_rows(rows, &count, diagnostics)
	return count
}

@(private = "file")
debug_overlay_diagnostic_rows :: proc(
	rows: []Debug_Overlay_Cell,
	count: ^int,
	diagnostics: Ui_Frame_Diagnostics,
) {
	debug_overlay_push(
		rows,
		count,
		"semantic ids / text",
		fmt.tprintf(
			"%d / %d",
			diagnostics.semantic_id_collisions,
			diagnostics.semantic_text_truncations,
		),
	)
	debug_overlay_push(
		rows,
		count,
		"paint cmd drops",
		fmt.tprintf(
			"%d / %d",
			diagnostics.main_commands_dropped,
			diagnostics.overlay_commands_dropped,
		),
	)
	debug_overlay_push(
		rows,
		count,
		"paint text / controls",
		fmt.tprintf(
			"%d / %d / %d",
			diagnostics.main_text_bytes_dropped,
			diagnostics.overlay_text_bytes_dropped,
			diagnostics.platform_controls_dropped,
		),
	)
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
		kv_row_frame(
			frame,
			x + pad,
			text_y,
			width - pad * 2,
			rows[index].key,
			rows[index].value,
			style.fg_secondary,
			style.fg_primary,
		)
		text_y += row_h
	}
	return height
}

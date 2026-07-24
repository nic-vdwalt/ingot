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

draw_debug_overlay :: proc(frame: ^Ui_Frame, x, y: i32, stats: Renderer_Diagnostics = {}) -> i32 {
	assert(frame != nil && frame.open, "draw_debug_overlay: invalid frame")
	assert(x >= 0 && y >= 0, "draw_debug_overlay: negative origin")
	metrics := ui_frame_metrics(frame)
	style := ui_frame_theme(frame)
	row_h := metrics.FONT_SIZE_SMALL + ui_frame_sc(frame, 4)
	pad := ui_frame_sc(frame, 8)
	width := ui_frame_sc(frame, 280)
	Cell :: struct { key, value: string }
	rows: [DEBUG_OVERLAY_MAX_ROWS]Cell
	count := 0
	push :: proc(rows: []Cell, count: ^int, key, value: string) {
		assert(count^ < len(rows), "draw_debug_overlay: row overflow")
		rows[count^] = {key, value}
		count^ += 1
	}
	push(rows[:], &count, "fps", fmt.tprintf("%d", frame_input(frame).fps))
	push(rows[:], &count, "frame", fmt.tprintf("%.2f ms", frame_input(frame).frame_time * 1000))
	push(rows[:], &count, "flushes", fmt.tprintf("%d", stats.flush_count))
	push(rows[:], &count, "vertices", fmt.tprintf("%d", stats.vertices_uploaded))
	push(rows[:], &count, "uploaded", fmt.tprintf("%d KB", stats.bytes_uploaded / 1024))
	push(rows[:], &count, "buffers new/grown", fmt.tprintf("%d / %d", stats.buffer_creations, stats.buffer_growths))
	push(rows[:], &count, "pipeline switches", fmt.tprintf("%d", stats.pipeline_switches))
	push(rows[:], &count, "render passes", fmt.tprintf("%d", stats.render_passes))
	push(rows[:], &count, "peak geom arena", fmt.tprintf("%d KB", stats.peak_arena_bytes / 1024))
	entries, evictions := measure_cache_stats_with(ui_frame_text(frame))
	push(rows[:], &count, "measure cache", fmt.tprintf("%d (%d evicted)", entries, evictions))
	push(rows[:], &count, "overlay cmds", fmt.tprintf("%d (%d dropped)", overlay_cmd_count(frame), overlay_dropped(frame)))
	push(rows[:], &count, "route claims", fmt.tprintf("%d", route_claim_count(frame)))
	height := i32(count) * row_h + pad * 2 + metrics.FONT_SIZE_SMALL + ui_frame_sc(frame, 6)
	panel := Rectangle{f32(x), f32(y), f32(width), f32(height)}
	draw_rectangle_rec(frame, panel, Color{style.bg_popup.r, style.bg_popup.g, style.bg_popup.b, 235})
	draw_rectangle_lines_ex(frame, panel, ui_frame_scf(frame, 1), style.border_color)
	text_y := y + pad
	draw_text_frame(frame, "DEBUG", x + pad, text_y, metrics.FONT_SIZE_SMALL, style.fg_label)
	text_y += metrics.FONT_SIZE_SMALL + ui_frame_sc(frame, 6)
	for index in 0 ..< count {
		kv_row_frame(frame, x + pad, text_y, width - pad * 2, rows[index].key, rows[index].value, style.fg_secondary, style.fg_primary)
		text_y += row_h
	}
	return height
}

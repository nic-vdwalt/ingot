// LIB-CANDIDATE: imports only core:* and ingot:gfx.
// Metrics/debug introspection overlay (ShowMetricsWindow, ingot-sized): FPS,
// frame time, renderer stats (flush counts by cause, uploads, buffer churn),
// text measure cache, and input-router/overlay counters. Renderer counters
// need the compile gate -define:INGOT_RENDER_STATS=true; without it those
// rows read zero. Draw it last so it sits above the app's own content.
package ui

import "core:fmt"
import rl "ingot:gfx"

// draw_debug_overlay draws the metrics panel with its top-left corner at
// (x, y) and returns the panel height. Call every frame while a debug toggle
// (say F12) is on.
draw_debug_overlay :: proc(frame: ^Ui_Frame, x, y: i32) -> i32 {
	assert(x >= 0 && y >= 0, "draw_debug_overlay: negative origin")
	s := rl.renderer_stats()
	metrics := ui_frame_metrics(frame)
	style := ui_frame_theme(frame)

	row_h := metrics.FONT_SIZE_SMALL + ui_frame_sc(frame, 4)
	pad := ui_frame_sc(frame, 8)
	w := ui_frame_sc(frame, 280)

	// Rows: fps, frame ms, flushes, per-cause breakdown (nonzero only),
	// vertices, uploaded KB, buffers, pipeline switches, passes, arenas,
	// measure cache, overlay cmds, route claims.
	Cell :: struct {
		key: string,
		val: string,
	}
	rows: [24]Cell
	n := 0
	push :: proc(rows: []Cell, n: ^int, key, val: string) {
		assert(n^ < len(rows), "draw_debug_overlay: row overflow")
		rows[n^] = Cell{key, val}
		n^ += 1
	}

	push(rows[:], &n, "fps", fmt.tprintf("%d", rl.GetFPS()))
	push(rows[:], &n, "frame", fmt.tprintf("%.2f ms", rl.GetFrameTime() * 1000))
	push(rows[:], &n, "flushes (draw calls)", fmt.tprintf("%d", s.flush_count))
	for cause in rl.Flush_Cause {
		c := s.flush_causes[cause]
		if c == 0 do continue
		push(rows[:], &n, fmt.tprintf("  %v", cause), fmt.tprintf("%d", c))
	}
	push(rows[:], &n, "vertices", fmt.tprintf("%d", s.vertices_uploaded))
	push(rows[:], &n, "uploaded", fmt.tprintf("%d KB", s.bytes_uploaded / 1024))
	push(
		rows[:],
		&n,
		"buffers new/grown",
		fmt.tprintf("%d / %d", s.buffer_creations, s.buffer_growths),
	)
	push(rows[:], &n, "pipeline switches", fmt.tprintf("%d", s.pipeline_switches))
	push(rows[:], &n, "render passes", fmt.tprintf("%d", s.render_passes))
	push(rows[:], &n, "peak geom arena", fmt.tprintf("%d KB", s.peak_geometry_arena_bytes / 1024))
	entries, evictions := measure_cache_stats_with(&frame.runtime.text)
	push(rows[:], &n, "measure cache", fmt.tprintf("%d (%d evicted)", entries, evictions))
	push(
		rows[:],
		&n,
		"overlay cmds",
		fmt.tprintf("%d (%d dropped)", overlay_cmd_count(frame), overlay_dropped(frame)),
	)
	push(rows[:], &n, "route claims", fmt.tprintf("%d", route_claim_count(frame)))

	h := i32(n) * row_h + pad * 2 + metrics.FONT_SIZE_SMALL + ui_frame_sc(frame, 6)
	panel := rl.Rectangle{f32(x), f32(y), f32(w), f32(h)}
	rl.DrawRectangleRec(panel, rl.Color{style.bg_popup.r, style.bg_popup.g, style.bg_popup.b, 235})
	rl.DrawRectangleLinesEx(panel, ui_frame_scf(frame, 1), style.border_color)

	ty := y + pad
	title: cstring = "DEBUG \u00b7 renderer stats"
	when !rl.RENDER_STATS_ENABLED {
		title = "DEBUG (build with -define:INGOT_RENDER_STATS=true)"
	}
	draw_text_frame(frame, title, x + pad, ty, metrics.FONT_SIZE_SMALL, style.fg_label)
	ty += metrics.FONT_SIZE_SMALL + ui_frame_sc(frame, 6)

	for i in 0 ..< n {
		kv_row_frame(
			frame,
			x + pad,
			ty,
			w - pad * 2,
			rows[i].key,
			rows[i].val,
			style.fg_secondary,
			style.fg_primary,
		)
		ty += row_h
	}
	return h
}

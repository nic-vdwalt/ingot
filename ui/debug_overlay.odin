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
draw_debug_overlay :: proc(x, y: i32) -> i32 {
	assert(x >= 0 && y >= 0, "draw_debug_overlay: negative origin")
	s := rl.renderer_stats()

	row_h := FONT_SIZE_SMALL + sc(4)
	pad := sc(8)
	w := sc(280)

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
	entries, evictions := measure_cache_stats()
	push(rows[:], &n, "measure cache", fmt.tprintf("%d (%d evicted)", entries, evictions))
	push(
		rows[:],
		&n,
		"overlay cmds",
		fmt.tprintf("%d (%d dropped)", overlay_cmd_count(), overlay_dropped()),
	)
	push(rows[:], &n, "route claims", fmt.tprintf("%d", route_claim_count()))

	h := i32(n) * row_h + pad * 2 + FONT_SIZE_SMALL + sc(6)
	panel := rl.Rectangle{f32(x), f32(y), f32(w), f32(h)}
	rl.DrawRectangleRec(panel, rl.Color{theme.bg_popup.r, theme.bg_popup.g, theme.bg_popup.b, 235})
	rl.DrawRectangleLinesEx(panel, 1, theme.border_color)

	ty := y + pad
	title: cstring = "DEBUG \u00b7 renderer stats"
	when !rl.RENDER_STATS_ENABLED {
		title = "DEBUG (build with -define:INGOT_RENDER_STATS=true)"
	}
	draw_text(title, x + pad, ty, FONT_SIZE_SMALL, theme.fg_label)
	ty += FONT_SIZE_SMALL + sc(6)

	for i in 0 ..< n {
		kv_row(
			x + pad,
			ty,
			w - pad * 2,
			rows[i].key,
			rows[i].val,
			theme.fg_secondary,
			theme.fg_primary,
		)
		ty += row_h
	}
	return h
}

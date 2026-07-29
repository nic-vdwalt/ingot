#+build !js
// Layout smoke harness (native only; -define:INGOT_LAYOUT_CHECK=true).
//
// Sweeps the derived layout across UI scales, window widths, and stepper
// states on the first frame, then exits. Every geometric invariant is an
// assert here or inside map_layout, so a regression fails the run rather
// than silently overlapping on screen:
//
//	odin run examples/api-map -collection:ingot=. -debug \
//		-define:INGOT_LAYOUT_CHECK=true
package main

import "core:fmt"
import "core:os"
import "ingot:ui"
import "ingot:ui_gfx"

CHECK_SCALES := [?]f32{0.75, 1.0, 1.25, 1.5, 2.0, 3.0}
CHECK_WIDTHS := [?]i32{760, 900, 1100, 1440, 1920, 2560}

layout_check :: proc(frame: ^ui.Ui_Frame) {
	assert(frame != nil, "layout_check: nil frame")
	runtime := ui_gfx.app_ui_runtime(&app)
	for scale in CHECK_SCALES {
		ui.ui_runtime_set_scale(runtime, scale)
		for width in CHECK_WIDTHS {
			physical := i32(f32(width) * scale)
			for phase in i32(0) ..= PHASE_COUNT {
				active_phase = phase
				l, total := map_layout(frame, 0, 0, physical)
				assert(total > 0, "layout_check: empty layout")
				assert(l.gfx.y + l.gfx.h <= total, "layout_check: gfx below canvas")
				assert(
					l.runtime.x + l.runtime.w < l.frame_card.x,
					"layout_check: row 1 overlaps",
				)
				assert(l.frame_card.x + l.frame_card.w < l.input.x, "layout_check: row 1 overlaps")
				assert(l.form.x + l.form.w < l.explicit.x, "layout_check: declare strip overlaps")
				assert(
					l.channels[2].x + l.channels[2].w <= l.output.x + l.output.w,
					"layout_check: channel escapes output box",
				)
				assert(
					l.input.x + l.input.w <= l.zone.x + l.zone.w,
					"layout_check: input escapes the zone",
				)
				assert(
					l.output.y > l.frame_card.y + l.frame_card.h,
					"layout_check: output overlaps row 1",
				)
				assert(
					l.adapter.y >= l.zone.y + l.zone.h,
					"layout_check: adapter overlaps the zone",
				)
				// The two drain channels must stay separable: main streams
				// live while overlay and platform replay at frame end.
				assert(
					l.col_main >= l.output.x && l.col_main < l.col_replay,
					"layout_check: drain channels collide",
				)
				assert(
					l.col_replay <= l.output.x + l.output.w,
					"layout_check: replay channel escapes output",
				)
				// Every badge sits at an arrow midpoint, so each channel must
				// be tall enough to hold one without touching either card.
				m := map_metrics(frame)
				assert(m.arrow_h > m.label * 2, "layout_check: badge clearance lost")
			}
			active_phase = 0
		}
		fmt.printfln("layout-check: scale %.2f ok", scale)
	}
	fmt.println("layout-check: ok")
	os.exit(0)
}

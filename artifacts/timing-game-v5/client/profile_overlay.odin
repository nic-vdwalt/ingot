package main

import "core:fmt"
import fit "ingot:fit"
import rl "ingot:gfx"

// Screen-space debug overlay for the phase profiler. Kept separate from
// profile.odin so the timing core stays GPU-free and unit-testable.
//
// The x/y anchors are authored at UI scale 1.0 and converted with ui_px; the
// row advance comes from fit's body role so rows never collide at >100%
// display scaling.

PROFILE_OVERLAY_X :: i32(18)
PROFILE_OVERLAY_Y :: i32(90)
// Gap between the header row and the phase list, and before the counters.
PROFILE_OVERLAY_GROUP_GAP :: i32(4)
// Phases quieter than this are folded away so the overlay stays readable; a
// phase that is cheap on average but spikes is still shown via the peak test.
PROFILE_OVERLAY_FLOOR_MS :: f64(0.02)
PROFILE_OVERLAY_PEAK_FLOOR_MS :: f64(1)

// profile_overlay_draw renders the phase timeline plus ingot's renderer
// counters. Rows are sorted by mean cost so the dominant phase is line one.
profile_overlay_draw :: proc(value: ^Client_State, surface: ^fit.Surface) {
	assert(value != nil, "profile_overlay_draw: nil state")
	assert(surface != nil, "profile_overlay_draw: nil surface")
	when PROFILE_ENABLED {
		profiler := &value.profiler
		if !profiler.visible || profiler.filled == 0 do return
		order: [len(Profile_Phase)]Profile_Phase
		summaries: [len(Profile_Phase)]Profile_Summary
		count := 0
		names := PROFILE_PHASE_NAMES
		for phase in Profile_Phase {
			if phase == .None do continue
			summary := profile_summary(
				profiler.samples[phase][:],
				profiler.filled,
				profiler.frame,
			)
			if summary.mean < PROFILE_OVERLAY_FLOOR_MS &&
			   summary.peak < PROFILE_OVERLAY_PEAK_FLOOR_MS {
				continue
			}
			// Insertion sort: at most 17 rows, so the simple form is the
			// right form and it needs no scratch buffer.
			slot := count
			for slot > 0 && summaries[slot - 1].mean < summary.mean {
				summaries[slot] = summaries[slot - 1]
				order[slot] = order[slot - 1]
				slot -= 1
			}
			summaries[slot] = summary
			order[slot] = phase
			count += 1
		}
		x := ui_px(value.ui_scale, PROFILE_OVERLAY_X)
		line_height := fit.Text_Line_Height(surface, .Body)
		group_gap := ui_px(value.ui_scale, PROFILE_OVERLAY_GROUP_GAP)
		y := ui_px(value.ui_scale, PROFILE_OVERLAY_Y)
		total := profile_summary(profiler.totals[:], profiler.filled, profiler.frame)
		header := fmt.tprintf(
			"frame  last %5.2f  mean %5.2f  peak %5.2f ms",
			total.last,
			total.mean,
			total.peak,
		)
		fit.Text(surface, header, x, y, .Title)
		y += fit.Text_Line_Height(surface, .Title) + group_gap
		for index in 0 ..< count {
			summary := summaries[index]
			line := fmt.tprintf(
				"%-14s %5.2f %5.2f %5.2f",
				names[order[index]],
				summary.last,
				summary.mean,
				summary.peak,
			)
			fit.Text(surface, line, x, y, .Body, .Secondary)
			y += line_height
		}
		// Renderer counters read zero unless the build defines
		// INGOT_RENDER_STATS=true; `bash build.sh profile` turns them on.
		stats := rl.renderer_stats()
		y += group_gap
		draws := fmt.tprintf(
			"draws %d  inst %d  verts %d  passes %d",
			stats.gpu3d_draws,
			stats.gpu3d_instanced_draws,
			stats.gpu3d_vertices_drawn,
			stats.render_passes,
		)
		fit.Text(surface, draws, x, y, .Body, .Secondary)
		y += line_height
		flora := fmt.tprintf(
			"flora scanned %d  drawn %d  of %d",
			value.flora.draw_visits,
			value.flora.draw_submitted,
			value.flora.count,
		)
		fit.Text(surface, flora, x, y, .Body, .Secondary)
	}
}

#+build !js
// Gallery smoke mode (scripts/smoke-gallery.sh, -define:INGOT_SMOKE=true):
// a self-driving crash harness. Every SMOKE_STEP_FRAMES frames it advances
// through scale presets × themes × contrast × reduced-motion × sections
// through the SAME handlers user input reaches (apply_scale,
// apply_gallery_theme, section switches), then exits 0. Any crash/abort
// (e.g. GPU validation) fails the script with a nonzero exit. Exists because
// the UI-scale mid-frame texture-destroy crash was reachable only through
// the real event path in a live window. Native-only (uses os.exit).
package main

import "core:fmt"
import "core:os"
import fit "ingot:fit"
import legacy "ingot:fit"
import gfx "ingot:gfx"

// Imports are used only under `when SMOKE`; anchor them for non-smoke builds.
_ :: fmt
_ :: os
_ :: fit
_ :: legacy
_ :: gfx

when SMOKE {
	SMOKE_STEP_FRAMES :: 20 // ~1/3 s per step at 60 fps
	SMOKE_SCALES := [?]f32{0.5, 0.75, 1.0, 1.5, 2.0, 3.0, 0} // 0 = auto

	// Theme steps: every palette, with reduced motion off and then on.
	//
	// This used to be four mutually exclusive steps derived from an index
	// (dark = t==0, high_contrast = t==2, reduced_motion = t==3), which meant
	// high contrast was only ever exercised with full motion and reduced
	// motion only ever with the light palette. The combinations never reached
	// were exactly the ones an accessibility user runs.
	//
	// It is now derived from the enum rather than listed, so a palette added
	// to the gallery is smoke-tested without anyone remembering to extend a
	// table. That matters because the sketch palettes take a drawing path the
	// screen ones do not - they carry a substrate, so a crash in the tooth or
	// margin code would otherwise surface only when a human happened to
	// select one.
	//
	// Motion stays a separate axis because it genuinely is orthogonal: it
	// applies to every palette, high contrast included.
	SMOKE_MOTION := [?]bool{false, true}
	smoke_theme_steps :: proc() -> int {
		return len(Palette) * 2
	}

	smoke_frame: int
	smoke_step_index: int

	smoke_step :: proc() {
		smoke_frame += 1
		if smoke_frame % SMOKE_STEP_FRAMES != 0 do return
		step := smoke_step_index
		smoke_step_index += 1

		scale_steps := len(SMOKE_SCALES)
		theme_steps := smoke_theme_steps()
		section_steps := len(Section)
		total := scale_steps + theme_steps + section_steps

		switch {
		case step < scale_steps:
			stored_scale = SMOKE_SCALES[step]
			apply_scale(stored_scale)
			fmt.printfln("smoke: scale %.2f", stored_scale)
		case step < scale_steps + theme_steps:
			// Palette advances fastest so each motion setting sweeps the whole
			// palette set, rather than one palette being tested twice in a row.
			index := step - scale_steps
			palette = Palette(index % len(Palette))
			reduced_motion = SMOKE_MOTION[index / len(Palette)]
			apply_gallery_theme()
			fmt.printfln("smoke: theme %s rm=%v", PALETTE_NAMES[palette], reduced_motion)
		case step < total:
			section = Section(step - scale_steps - theme_steps)
			legacy.pane_reset(&content_pane)
			fmt.printfln("smoke: section %s", SECTION_NAMES[section])
		case:
			smoke_report_peaks()
			fmt.printfln("smoke: ok (%d steps)", total)
			os.exit(0)
		}
	}

	// smoke_report_peaks prints the high-water marks the run reached against
	// the capacities reserved for them. Those capacities are static inline
	// arrays (gfx.BATCH_MAX_VERTICES, legacy.PAINT_COMMAND_CAP), so unused
	// headroom is memory resident for the whole session - about 20 MB of it
	// on this app. The smoke run visits every section, including the 1000
	// button stress grid, so these numbers are the evidence for sizing them.
	smoke_report_peaks :: proc() {
		usage := gfx.renderer_peak_usage()
		// A full run that drew every section cannot legitimately report a
		// zero peak: that means the recording call was lost, and the numbers
		// the capacities are sized from would silently become fiction. Unit
		// tests cannot cover renderer_flush's call site (it needs a live GPU
		// pass), so this run is where that wiring is verified.
		assert(usage.vertices > 0, "smoke: no vertex peak recorded - peak tracking is broken")
		assert(usage.indices > 0, "smoke: no index peak recorded - peak tracking is broken")
		assert(
			usage.vertices <= usage.vertices_capacity,
			"smoke: vertex peak exceeded its capacity",
		)
		fmt.printfln(
			"smoke: peak vertices %d/%d (%.1f%%), indices %d/%d (%.1f%%)",
			usage.vertices,
			usage.vertices_capacity,
			f64(usage.vertices) * 100 / f64(max(usage.vertices_capacity, 1)),
			usage.indices,
			usage.indices_capacity,
			f64(usage.indices) * 100 / f64(max(usage.indices_capacity, 1)),
		)
		fmt.printfln(
			"smoke: peak streams geometry %d/%d KiB, uniform %d/%d KiB",
			usage.geometry_stream_bytes / 1024,
			usage.geometry_capacity_bytes / 1024,
			usage.uniform_stream_bytes / 1024,
			usage.uniform_capacity_bytes / 1024,
		)
		peaks := fit.Paint_Peak_Usage(&app)
		assert(peaks.main_commands > 0, "smoke: no paint peak recorded")
		fmt.printfln(
			"smoke: peak paint main %d/%d cmds %d/%d text, overlay %d/%d cmds %d/%d text",
			peaks.main_commands,
			legacy.PAINT_COMMAND_CAP,
			peaks.main_text_bytes,
			legacy.PAINT_TEXT_CAP,
			peaks.overlay_commands,
			legacy.PAINT_COMMAND_CAP,
			peaks.overlay_text_bytes,
			legacy.PAINT_TEXT_CAP,
		)
	}
}

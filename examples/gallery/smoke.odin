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
import "ingot:ui"

// Imports are used only under `when SMOKE`; anchor them for non-smoke builds.
_ :: fmt
_ :: os
_ :: ui

when SMOKE {
	SMOKE_STEP_FRAMES :: 20 // ~1/3 s per step at 60 fps
	SMOKE_SCALES := [?]f32{0.5, 0.75, 1.0, 1.5, 2.0, 3.0, 0} // 0 = auto
	smoke_frame: int
	smoke_step_index: int

	smoke_step :: proc() {
		smoke_frame += 1
		if smoke_frame % SMOKE_STEP_FRAMES != 0 do return
		step := smoke_step_index
		smoke_step_index += 1

		scale_steps := len(SMOKE_SCALES)
		theme_steps := 4 // dark, light, high contrast, reduced motion
		section_steps := len(Section)
		total := scale_steps + theme_steps + section_steps

		switch {
		case step < scale_steps:
			stored_scale = SMOKE_SCALES[step]
			apply_scale(stored_scale)
			fmt.printfln("smoke: scale %.2f", stored_scale)
		case step < scale_steps + theme_steps:
			t := step - scale_steps
			dark = t == 0
			high_contrast = t == 2
			reduced_motion = t == 3
			apply_gallery_theme()
			fmt.printfln("smoke: theme step %d (hc=%v rm=%v)", t, high_contrast, reduced_motion)
		case step < total:
			section = Section(step - scale_steps - theme_steps)
			ui.pane_reset(&content_pane)
			fmt.printfln("smoke: section %s", SECTION_NAMES[section])
		case:
			fmt.printfln("smoke: ok (%d steps)", total)
			os.exit(0)
		}
	}
}

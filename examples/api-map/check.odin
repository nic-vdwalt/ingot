#+build !js
package main

import "core:fmt"
import "core:os"

CHECK_WIDTHS := [?]i32{320, 760, 1180, 1920, 2560}

layout_check :: proc() {
	for width in CHECK_WIDTHS {
		assert(width > 0)
		for phase in i32(0) ..= PHASE_COUNT {
			active_phase = phase
			assert(len(PHASE_CAPTIONS[phase]) > 0)
			assert(len(MAP_NODES) == PHASE_COUNT)
		}
		fmt.printfln("layout-check: width %d ok", width)
	}
	active_phase = 0
	fmt.println("layout-check: ok")
	os.exit(0)
}

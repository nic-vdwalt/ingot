#+build !js
package main

when MAP_CAPTURE {
	map_capture_main :: proc() {
		map_state = {
			selected_stage = STAGE_COUNT,
			target_stage   = STAGE_COUNT,
			hovered_node   = -1,
			dark           = true,
			progress       = 1,
		}
		layout_check()
	}
}

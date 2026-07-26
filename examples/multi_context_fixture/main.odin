package main

import "core:fmt"
import rl "ingot:gfx"

secondary: rl.Context

main :: proc() {
	primary := rl.default_context()
	if !rl.context_init(primary, 640, 360, "Ingot context fixture") {
		fmt.eprintln("multi_context_fixture: primary context initialization failed")
		return
	}
	defer rl.context_close(primary)

	if !rl.context_init(&secondary, 320, 240, "Ingot secondary context") {
		panic("multi_context_fixture: secondary context initialization failed")
	}
	defer rl.context_close(&secondary)

	for frame_index in 0 ..< 120 {
		primary_frame, primary_ok := rl.context_begin_frame(primary)
		if primary_ok {
			rl.clear_frame(&primary_frame, rl.Color{24, 28, 38, 255})
			rl.draw_rect(&primary_frame, {32, 32, 160, 80}, rl.Color{76, 154, 255, 255})
			rl.end_frame(&primary_frame)
		}
		secondary_frame, secondary_ok := rl.context_begin_frame(&secondary)
		if secondary_ok {
			rl.clear_frame(&secondary_frame, rl.Color{38, 24, 28, 255})
			rl.draw_circle(&secondary_frame, {160, 120}, 48, rl.Color{255, 130, 110, 255})
			rl.end_frame(&secondary_frame)
		}
		if rl.context_should_close(primary) || rl.context_should_close(&secondary) do break
	}
	rl.context_close(primary)
	secondary_frame, secondary_ok := rl.context_begin_frame(&secondary)
	if secondary_ok {
		rl.clear_frame(&secondary_frame, rl.Color{20, 35, 28, 255})
		rl.end_frame(&secondary_frame)
	}
	fmt.println("multi_context_fixture: independent contexts validated")
}

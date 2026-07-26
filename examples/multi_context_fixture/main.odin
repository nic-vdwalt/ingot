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

	if rl.context_init(&secondary, 320, 240, "Ingot secondary context") {
		panic("multi_context_fixture: non-default context unexpectedly initialized")
	}
	if !rl.context_should_close(&secondary) {
		panic("multi_context_fixture: unavailable secondary context must report closed")
	}

	frame, ok := rl.context_begin_frame(primary)
	if !ok do return
	rl.clear_frame(&frame, rl.Color{24, 28, 38, 255})
	rl.draw_rect(&frame, {32, 32, 160, 80}, rl.Color{76, 154, 255, 255})
	rl.end_frame(&frame)
	fmt.println(
		"multi_context_fixture: default context validated; simultaneous windows remain gated",
	)
}

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
	for _ in 0 ..< 120 {
		draw_context(primary, rl.Color{24, 28, 38, 255}, true)
		draw_context(&secondary, rl.Color{38, 24, 28, 255}, false)
		if rl.context_should_close(primary) || rl.context_should_close(&secondary) do break
	}
	fmt.printfln(
		"multi_context_fixture: frame delivery primary=%v secondary=%v",
		rl.context_frame_delivery_supported(primary),
		rl.context_frame_delivery_supported(&secondary),
	)
	fmt.printfln(
		"multi_context_fixture: overflow reports primary=%d secondary=%d",
		rl.context_renderer_overflow_reports(primary),
		rl.context_renderer_overflow_reports(&secondary),
	)
	secondary_delivery := rl.context_frame_delivery_supported(&secondary)
	rl.context_close(primary)
	draw_context(&secondary, rl.Color{20, 35, 28, 255}, false)
	if rl.context_frame_delivery_supported(&secondary) != secondary_delivery {
		panic("multi_context_fixture: closing primary changed secondary frame delivery")
	}
	fmt.println("multi_context_fixture: independent contexts validated")
}

draw_context :: proc(ctx: ^rl.Context, background: rl.Color, rectangle: bool) {
	frame: rl.Frame
	available := rl.frame_begin(&frame, ctx)
	defer rl.frame_end(&frame)
	if !available do return
	_ = background
	if rectangle {
		rl.frame_draw_rectangle(&frame, {32, 32, 160, 80}, rl.Color{76, 154, 255, 255})
	} else {
		rl.frame_draw_circle(&frame, {160, 120}, 48, rl.Color{255, 130, 110, 255})
	}
}

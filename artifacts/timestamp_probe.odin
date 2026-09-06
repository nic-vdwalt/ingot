package main

import "core:fmt"
import rl "ingot:gfx"

main :: proc() {
	rl.InitWindow(640, 480, "Timestamp probe")
	rl.SetTargetFPS(120)
	valid, invalid: u64
	for frame in 0 ..< 1200 {
		rl.BeginDrawing()
		rl.ClearBackground(rl.Color{20, 30, 40, 255})
		rl.DrawRectangle(0, 0, 640, 480, rl.Color{50, 60, 70, 255})
		rl.EndDrawing()
		output: [128]rl.Gpu_Frame_Timing_Detail
		count, health := rl.context_renderer_gpu_timing_drain(rl.default_context(), output[:])
		valid += u64(count)
		invalid += health.invalid_timestamps
		if health.first_invalid_pair.valid {
			pair := health.first_invalid_pair
			fmt.printf("frame=%d begin=%d end=%d\n", frame, pair.begin_tick, pair.end_tick)
		}
	}
	fmt.printf("valid=%d invalid=%d\n", valid, invalid)
	rl.CloseWindow()
}

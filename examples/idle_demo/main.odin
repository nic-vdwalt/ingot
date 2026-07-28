// idle_demo - proves event-driven frame scheduling (power-save mode).
//
// The overlay shows a frame counter and FPS: when you stop interacting the
// counter freezes within IDLE_SETTLE_FRAMES frames (~0% CPU; check with a
// process monitor), and resumes instantly on mouse/keyboard input. The caret
// box keeps blinking while focused via RequestRedrawIn - timed repaints work
// without continuous rendering. Click the button to toggle back to
// .Continuous and watch the counter free-run again.
//
//	odin run examples/idle_demo -collection:ingot=.
package main

import "core:fmt"
import "core:strings"
import rl "ingot:gfx"

FONT_TTF := #load("../../assets/fonts/JetBrainsMono-Regular.ttf")

font: rl.Font
frame_count: u64
text_buf: strings.Builder

main :: proc() {
	rl.InitWindow(640, 400, "ingot idle demo")
	rl.EnableEventWaiting() // opt in to event-driven frames
	font = rl.LoadFontFromMemory(".ttf", raw_data(FONT_TTF), i32(len(FONT_TTF)), 20, nil, 0)
	strings.builder_init(&text_buf)
	rl.run(frame)
}

frame :: proc() {
	frame_count += 1

	// Text input: append typed runes, backspace deletes.
	for {
		r := rl.GetCharPressed()
		if r == 0 do break
		strings.write_rune(&text_buf, r)
	}
	if rl.IsKeyPressed(.BACKSPACE) || rl.IsKeyPressedRepeat(.BACKSPACE) {
		s := strings.to_string(text_buf)
		if len(s) > 0 {
			// pop last rune
			i := len(s) - 1
			for i > 0 && (s[i] & 0xC0) == 0x80 do i -= 1
			resize(&text_buf.buf, i)
		}
	}

	// Button hit-test.
	btn := rl.Rectangle{20, 20, 260, 40}
	mouse := rl.GetMousePosition()
	hovered := rl.CheckCollisionPointRec(mouse, btn)
	if hovered && rl.IsMouseButtonPressed(.LEFT) {
		if rl.GetFrameStrategy() == .Event_Driven {
			rl.DisableEventWaiting()
		} else {
			rl.EnableEventWaiting()
		}
	}

	rl.BeginDrawing()
	rl.ClearBackground(rl.Color{22, 24, 32, 255})

	// Strategy toggle button.
	bg := hovered ? rl.Color{70, 90, 140, 255} : rl.Color{50, 62, 96, 255}
	rl.DrawRectangleRec(btn, bg)
	label: cstring =
		rl.GetFrameStrategy() == .Event_Driven ? "strategy: Event_Driven" : "strategy: Continuous"
	rl.DrawTextEx(font, label, {32, 30}, 20, 0, rl.RAYWHITE)

	// Text input box with a blinking caret (timed repaints while idle).
	box := rl.Rectangle{20, 80, 600, 40}
	rl.DrawRectangleRec(box, rl.Color{34, 38, 52, 255})
	rl.DrawRectangleLinesEx(box, 1, rl.Color{80, 90, 120, 255})
	txt := strings.clone_to_cstring(strings.to_string(text_buf), context.temp_allocator)
	rl.DrawTextEx(font, txt, {28, 90}, 20, 0, rl.RAYWHITE)
	tw := rl.MeasureTextEx(font, txt, 20, 0).x
	rl.RequestRedrawIn(0.5) // schedule the next blink toggle
	if int(rl.GetTime() * 2) % 2 == 0 {
		rl.DrawRectangleRec({28 + tw + 2, 88, 2, 24}, rl.Color{120, 180, 255, 255})
	}

	// Frame counter + FPS overlay: freezes when idle, free-runs when active.
	stats := fmt.ctprintf(
		"frame %d   fps %d   type to wake; idle freezes this counter",
		frame_count,
		rl.GetFPS(),
	)
	rl.DrawTextEx(font, stats, {20, 150}, 20, 0, rl.Color{140, 200, 140, 255})

	rl.EndDrawing()
	free_all(context.temp_allocator)
}

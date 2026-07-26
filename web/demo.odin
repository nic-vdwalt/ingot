// ingot web demo — the REAL ingot:gfx engine compiled to WASM + WebGPU.
//
// Unlike the original standalone spike (which hand-rolled its own wgpu surface
// and pipeline), this drives the actual engine: InitWindow → run(frame), the
// same source that runs natively. Proves the platform seam (canvas surface,
// async device init, performance.now timing, RAF-driven loop) end-to-end.
//
// Build:  bash build_web.sh   (see that script)
// Serve:  (cd web && python3 -m http.server 8000), open index.html in a WebGPU
//         browser (Chrome/Edge 113+, Safari 18+).
package web

import rl "ingot:gfx"

// Embed a font so the demo exercises the real text atlas (stb_truetype → R8 wgpu
// upload) in-browser, proving the text stack works on the web target.
FONT_TTF := #load("../assets/fonts/JetBrainsMonoNerdFontMono-Regular.ttf")
DEMO_CPS := [?]rune {
	' ',
	'!',
	':',
	'A',
	'G',
	'P',
	'U',
	'W',
	'b',
	'c',
	'd',
	'e',
	'f',
	'g',
	'h',
	'i',
	'l',
	'n',
	'o',
	'p',
	'r',
	's',
	't',
	'u',
	'w',
	'x',
	'y',
}

font: rl.Font
font_ready: bool

main :: proc() {
	rl.InitWindow(1280, 720, "ingot web demo")
	rl.SetTargetFPS(60)
	rl.run(frame) // native: blocks; web: returns, RAF drives frame()
}

t: f32

// frame draws one frame; identical on native and web.
frame :: proc() {
	t += rl.GetFrameTime()

	// Bake the font atlas on the first frame after the GPU device is ready.
	if !font_ready {
		font = rl.LoadFontFromMemory(
			".ttf",
			raw_data(FONT_TTF),
			i32(len(FONT_TTF)),
			28,
			raw_data(DEMO_CPS[:]),
			i32(len(DEMO_CPS)),
		)
		font_ready = font.glyphCount > 0
	}

	rl.BeginDrawing()
	rl.ClearBackground(rl.Color{30, 34, 48, 255})

	// a couple of moving shapes so motion is visible and the batch renderer,
	// ortho projection, and per-frame timing are all exercised
	w := rl.GetScreenWidth()
	h := rl.GetScreenHeight()
	cx := f32(w) * 0.5
	cy := f32(h) * 0.5
	off := 120.0 * _sin(t)

	rl.DrawRectangle(i32(cx - 100 + off), i32(cy - 60), 200, 120, rl.Color{60, 100, 255, 255})
	rl.DrawCircle(i32(cx - off), i32(cy), 48, rl.Color{255, 140, 60, 255})

	// real text via the stb_truetype atlas (not the DrawText stub)
	if font_ready {
		rl.DrawTextEx(
			font,
			"ingot gfx on WebGPU",
			rl.Vector2{24, 24},
			28,
			1,
			rl.Color{230, 230, 235, 255},
		)
	}

	// input demo: a marker follows the mouse; it turns green while held. Proves
	// the DOM→engine input path (pointer move + button) end-to-end in-browser.
	m := rl.GetMousePosition()
	held := rl.IsMouseButtonDown(.LEFT)
	mc := held ? rl.Color{80, 220, 120, 255} : rl.Color{220, 220, 230, 255}
	rl.DrawCircle(i32(m.x), i32(m.y), 10, mc)
	if rl.IsKeyPressed(.SPACE) {
		t = 0 // press Space to reset the animation — proves key events arrive
	}

	rl.EndDrawing()
	free_all(context.temp_allocator)
}

// small periodic sine to avoid pulling extra deps on the wasm target
_sin :: proc(x: f32) -> f32 {
	PI :: f32(3.14159265)
	xx := x
	for xx > PI do xx -= 2 * PI
	for xx < -PI do xx += 2 * PI
	a := xx < 0 ? -xx : xx
	return 4.0 / PI * xx - 4.0 / (PI * PI) * xx * a
}

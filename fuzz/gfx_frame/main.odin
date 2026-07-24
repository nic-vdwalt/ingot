package fuzz_gfx_frame

// GPU resource-lifecycle fuzzer for ingot:gfx — WINDOWED (opens a real
// window and a real WebGPU device; excluded from `fuzz/run.sh all`).
//
// Motivation: the UI-scale crash class. Destroying a texture between
// BeginDrawing and QueueSubmit while recorded draws still reference it fails
// wgpu validation and aborts the process. That temporal-ordering bug is
// invisible to headless tests and the parser fuzzers, so this harness runs
// real frames and interleaves resource churn *inside* them:
//
//   - draw text (captures font-atlas references in the command buffer)
//   - draw textures / render-target passes (captures texture references)
//   - then, mid-frame: reset_font_atlases, UnloadTexture,
//     UnloadRenderTexture, set_ui_scale, set_theme, dpi changes
//
// Any wgpu validation abort = crash with a reproducible seed (printed
// FIRST):
//   fuzz_gfx_frame -seed:12345 -iterations:400
//
// One iteration = one frame. Iterations default low: frames cost ~1 ms and
// the bug class needs ordering coverage, not volume.

import "core:fmt"
import "core:mem"
import fuzzx "ingot:fuzz/fuzzx"
import rl "ingot:gfx"
import "ingot:ui"

ITERATIONS_DEFAULT :: 400
MAX_LIVE_TEXTURES :: 8
MAX_LIVE_TARGETS :: 4

Prng :: fuzzx.Prng

live_textures: [MAX_LIVE_TEXTURES]rl.Texture2D
live_targets: [MAX_LIVE_TARGETS]rl.RenderTexture2D
ui_runtime: ui.Ui_Runtime
ui_frame: ui.Ui_Frame

make_texture :: proc(p: ^Prng) -> rl.Texture2D {
	w := i32(fuzzx.int_range(p, 1, 65))
	h := i32(fuzzx.int_range(p, 1, 65))
	pixels := make([]u8, int(w * h * 4), context.temp_allocator)
	for i in 0 ..< len(pixels) do pixels[i] = u8(fuzzx.next_u64(p) & 0xFF)
	img := rl.Image {
		data    = raw_data(pixels),
		width   = w,
		height  = h,
		mipmaps = 1,
		format  = .UNCOMPRESSED_R8G8B8A8,
	}
	return rl.LoadTextureFromImage(img)
}

// draw_some records draws referencing current resources so the frame's
// command buffer actually captures them — the precondition for the bug.
draw_some :: proc(p: ^Prng) {
	ui.draw_text("lifecycle fuzz", 10, 10, ui.FONT_SIZE, ui.theme.fg_primary)
	ui.draw_text("0123456789", 10, 40, ui.FONT_SIZE_SMALL, ui.theme.fg_secondary)
	for t in live_textures {
		if t.id == 0 do continue
		rl.DrawTexture(
			t,
			i32(fuzzx.int_range(p, 0, 200)),
			i32(fuzzx.int_range(p, 0, 200)),
			rl.WHITE,
		)
	}
	for rt in live_targets {
		if rt.id == 0 do continue
		rl.BeginTextureMode(rt)
		rl.ClearBackground(rl.Color{20, 20, 20, 255})
		ui.draw_text("rt", 2, 2, ui.FONT_SIZE_SMALL, ui.theme.fg_primary)
		rl.EndTextureMode()
		src := rl.Rectangle{0, 0, f32(rt.texture.width), -f32(rt.texture.height)}
		dst := rl.Rectangle{240, 10, 64, 64}
		rl.DrawTexturePro(rt.texture, src, dst, {0, 0}, 0, rl.WHITE)
	}
}

// mutate_resources performs one random lifecycle op — the destroy/rescale
// half of the interleave. Weighted so unload/rescale (the dangerous ops)
// dominate.
mutate_resources :: proc(p: ^Prng) {
	switch fuzzx.int_range(p, 0, 13) {
	case 0, 1:
		// Load a texture into a random slot (unloading any occupant first).
		slot := fuzzx.int_range(p, 0, MAX_LIVE_TEXTURES)
		if live_textures[slot].id != 0 do rl.UnloadTexture(live_textures[slot])
		live_textures[slot] = make_texture(p)
	case 2, 3:
		// Unload a texture that this frame may already have drawn.
		slot := fuzzx.int_range(p, 0, MAX_LIVE_TEXTURES)
		if live_textures[slot].id != 0 {
			rl.UnloadTexture(live_textures[slot])
			live_textures[slot] = {}
		}
	case 4:
		slot := fuzzx.int_range(p, 0, MAX_LIVE_TARGETS)
		if live_targets[slot].id != 0 do rl.UnloadRenderTexture(live_targets[slot])
		live_targets[slot] = rl.LoadRenderTexture(
			i32(fuzzx.int_range(p, 8, 129)),
			i32(fuzzx.int_range(p, 8, 129)),
		)
	case 5:
		slot := fuzzx.int_range(p, 0, MAX_LIVE_TARGETS)
		if live_targets[slot].id != 0 {
			rl.UnloadRenderTexture(live_targets[slot])
			live_targets[slot] = {}
		}
	case 6, 7:
		// The original crash: rescale mid-frame unloads every font atlas
		// referenced by draws already recorded this frame.
		scale := f32(fuzzx.int_range(p, 50, 301)) / 100.0
		ui.ui_runtime_set_scale(&ui_runtime, scale)
	case 8:
		switch fuzzx.int_range(p, 0, 3) {
		case 0:
			ui.ui_runtime_set_theme(&ui_runtime, ui.theme_dark())
		case 1:
			ui.ui_runtime_set_theme(&ui_runtime, ui.theme_light())
		case 2:
			ui.ui_runtime_set_theme(&ui_runtime, ui.theme_high_contrast())
		}
	case 9:
		ui.set_font_dpi(f32(fuzzx.int_range(p, 100, 301)) / 100.0)
		ui.reset_font_atlases()
	case 10, 11:
		// Surface lifecycle: resize mid-frame (swapchain reconfigure),
		// including repeated same-size calls (must be idempotent).
		w := i32(fuzzx.int_range(p, 200, 2001))
		h := i32(fuzzx.int_range(p, 150, 1501))
		if fuzzx.int_range(p, 0, 4) == 0 {
			w = rl.GetScreenWidth() // same-size resize
			h = rl.GetScreenHeight()
		}
		rl.SetWindowSize(w, h)
	case 12:
		// Compound case: resize immediately followed by UI rescale — the
		// swapchain reconfigure + atlas churn interleaving.
		rl.SetWindowSize(i32(fuzzx.int_range(p, 300, 1601)), i32(fuzzx.int_range(p, 200, 1201)))
		ui.ui_runtime_set_scale(&ui_runtime, f32(fuzzx.int_range(p, 50, 301)) / 100.0)
	}

}

main :: proc() {
	seed, iterations, rounds := fuzzx.parse_options(ITERATIONS_DEFAULT)
	fmt.printfln("fuzz_gfx_frame seed=%d iterations=%d rounds=%d", seed, iterations, rounds)

	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	context.allocator = mem.tracking_allocator(&track)

	rl.InitWindow(480, 320, "gfx frame lifecycle fuzz")
	rl.SetTargetFPS(0) // uncapped: iterations bound the run, not wall time
	ui.init_font()
	ui.ui_runtime_init(&ui_runtime)

	for round in 0 ..< rounds {
		round_seed := seed + u64(round)
		if rounds > 1 do fmt.printfln("fuzz_gfx_frame round %d seed=%d", round, round_seed)
		p := fuzzx.prng_make(round_seed)
		for i in 0 ..< iterations {
			if rl.WindowShouldClose() do break
			ui.ui_frame_begin(&ui_frame, &ui_runtime)
			rl.BeginDrawing()
			rl.ClearBackground(ui.theme.bg_color)

			// Interleave draw → mutate → draw so recorded references
			// always precede the destroy in ordering-sensitive cases.
			draw_some(&p)
			ops := fuzzx.int_range(&p, 0, 5)
			for _ in 0 ..< ops {
				mutate_resources(&p)
				if fuzzx.int_range(&p, 0, 2) == 0 do draw_some(&p)
			}

			ui.ui_frame_end(&ui_frame)
			rl.EndDrawing()
			free_all(context.temp_allocator)
			_ = i
		}
	}

	// Teardown outside any frame exercises the immediate-destroy path.
	for t in live_textures do if t.id != 0 do rl.UnloadTexture(t)
	for rt in live_targets do if rt.id != 0 do rl.UnloadRenderTexture(rt)
	ui.ui_runtime_destroy(&ui_runtime)
	rl.CloseWindow()

	fmt.printfln("fuzz_gfx_frame ok")
}

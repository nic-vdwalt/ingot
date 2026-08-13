#+build !js
// Still-capture harness (native only; -define:INGOT_MAP_CAPTURE=true).
//
// Renders the api map into a fixed offscreen target and saves one
// deterministic PNG per theme, then exits - the README screenshot pipeline,
// mirroring examples/gallery/capture.odin. The swapchain is
// RenderAttachment-only, so gfx.SaveRenderTexturePng can only read a render
// target; a fixed target also decouples output from the host window and DPI.
//
//	odin run examples/api-map -collection:ingot=. \
//		-define:INGOT_MAP_CAPTURE=true
//
// Writes docs/media/api-map-dark.png and api-map-light.png (override the
// directory with INGOT_CAPTURE_DIR).
package main

import "core:fmt"
import "core:os"
import "core:strings"
import rl "ingot:gfx"
import ui "ingot:fit"
import ui_gfx "ingot:fit"

// Imports are used only under `when MAP_CAPTURE`; anchor them for normal
// builds, matching examples/gallery/capture.odin.
_ :: fmt
_ :: os
_ :: strings
_ :: rl
_ :: ui
_ :: ui_gfx

when MAP_CAPTURE {
	// Fixed output geometry: identical PNGs regardless of host display. The
	// target is 2x the logical composition (UI scale doubled with it), so the
	// README still stays crisp on HiDPI displays; the first frame asserts
	// nothing falls outside the target.
	MAP_CAPTURE_WIDTH :: 3200
	MAP_CAPTURE_HEIGHT :: 2000
	MAP_CAPTURE_WINDOW_WIDTH :: 1280
	MAP_CAPTURE_WINDOW_HEIGHT :: 800
	MAP_CAPTURE_UI_SCALE :: f32(2.3)
	// Frames to hold before each shot so fonts, DPI, and theme all settle.
	MAP_CAPTURE_SETTLE_FRAMES :: 30

	Map_Capture_Shot :: struct {
		file: string,
		dark: bool,
	}

	MAP_CAPTURE_SHOTS := [?]Map_Capture_Shot {
		{"api-map-dark.png", true},
		{"api-map-light.png", false},
	}

	map_capture_dir: string
	map_capture_target: rl.RenderTexture2D
	map_capture_index: int
	map_capture_frame_count: int
	map_capture_applied: bool

	map_capture_step :: proc() {
		if map_capture_index >= len(MAP_CAPTURE_SHOTS) {
			map_capture_finish()
		}
		shot := MAP_CAPTURE_SHOTS[map_capture_index]
		if !map_capture_applied {
			dark = shot.dark
			active_phase = 0
			apply_theme()
			ui.ui_runtime_set_scale(ui_gfx.app_ui_runtime(&app), MAP_CAPTURE_UI_SCALE)
			map_capture_applied = true
			map_capture_frame_count = 0
			return
		}
		map_capture_frame_count += 1
	}

	map_capture_write :: proc() {
		if !map_capture_applied || map_capture_frame_count < MAP_CAPTURE_SETTLE_FRAMES do return
		shot := MAP_CAPTURE_SHOTS[map_capture_index]
		path := fmt.tprintf("%s/%s", map_capture_dir, shot.file)
		// The whole diagram must fit the target: recompute the derived height
		// at the capture width and fail loudly instead of shipping a cropped
		// README image.
		frame := &app.session.frame
		if frame.open {
			_, total := map_layout(frame, 0, 0, MAP_CAPTURE_WIDTH - ui.ui_frame_sc(frame, 52))
			toolbar := ui.ui_frame_metrics(frame).TAB_BAR_HEIGHT + ui.ui_frame_sc(frame, 150)
			if total + toolbar > MAP_CAPTURE_HEIGHT {
				fmt.eprintfln(
					"capture: diagram %d + toolbar %d exceeds target height %d",
					total,
					toolbar,
					MAP_CAPTURE_HEIGHT,
				)
				os.exit(1)
			}
		}
		if !rl.SaveRenderTexturePng(map_capture_target, path) {
			fmt.eprintfln("capture: failed to write %s", path)
			os.exit(1)
		}
		fmt.printfln("capture: wrote %s", path)
		map_capture_index += 1
		map_capture_applied = false
	}

	map_capture_finish :: proc() {
		if map_capture_target.texture.id != 0 do rl.UnloadRenderTexture(map_capture_target)
		os.exit(0)
	}

	map_capture_frame :: proc() {
		frame, acquired := ui_gfx.session_acquire_frame(&app.session)
		if !acquired do return
		frame_state := frame.ui
		// Captured media is flat artwork: app_clear_color takes the theme
		// colour and drops the window translucency (see gallery capture.odin
		// for the full rationale).
		background := ui_gfx.app_clear_color(&app)
		rl.ClearBackground(background)

		map_capture_step()
		rl.BeginTextureMode(map_capture_target)
		rl.ClearBackground(background)
		map_frame(&app, frame_state, nil)
		rl.EndTextureMode()

		// Negative source height blits the bottom-left-origin target upright.
		rl.DrawTexturePro(
			map_capture_target.texture,
			{0, 0, f32(MAP_CAPTURE_WIDTH), -f32(MAP_CAPTURE_HEIGHT)},
			{0, 0, f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight())},
			{0, 0},
			0,
			rl.WHITE,
		)
		ui_gfx.session_present_frame(&frame)
		map_capture_write()
		free_all(context.temp_allocator)
	}

	map_capture_main :: proc() {
		map_capture_dir = os.get_env("INGOT_CAPTURE_DIR", context.allocator)
		if map_capture_dir == "" do map_capture_dir = strings.clone("docs/media")
		started := ui_gfx.app_init(
			&app,
			{
				width = MAP_CAPTURE_WINDOW_WIDTH,
				height = MAP_CAPTURE_WINDOW_HEIGHT,
				title = "ingot api map (capture)",
				target_fps = 60,
				event_waiting = false,
				session = {semantics_enabled = true},
			},
			{frame = map_frame},
		)
		if !started {
			fmt.eprintln("capture: window initialisation failed")
			os.exit(1)
		}
		app.state = .Running
		map_capture_target = rl.LoadRenderTexture(MAP_CAPTURE_WIDTH, MAP_CAPTURE_HEIGHT)
		if map_capture_target.texture.id == 0 {
			fmt.eprintln("capture: render target allocation failed")
			os.exit(1)
		}
		fmt.printfln("capture: stills into %s", map_capture_dir)
		rl.run(map_capture_frame)
	}
}

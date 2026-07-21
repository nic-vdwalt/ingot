package main

import "core:fmt"
import rl "ingot:gfx"

FONT_TTF := #load("../../assets/fonts/JetBrainsMonoNerdFontMono-Regular.ttf")
FIXTURE_CPS := [?]rune{' ', ':', 'A', 'B', 'C', 'F', 'G', 'P', 'R', 'T', 'U', 'a', 'c', 'e', 'f', 'g', 'i', 'm', 'n', 'o', 'r', 's', 't', 'x'}

font: rl.Font
font_ready: bool
source_texture: rl.Texture2D
primary_rt: rl.RenderTexture2D
ping_rt: rl.RenderTexture2D
pong_rt: rl.RenderTexture2D
resources_ready: bool

main :: proc() {
	rl.InitWindow(960, 720, "ingot renderer fixture")
	rl.SetTargetFPS(60)
	rl.run(frame)
}

frame :: proc() {
	ensure_resources()
	rl.BeginDrawing()
	rl.ClearBackground(rl.Color{22, 24, 32, 255})
	if resources_ready {
		draw_render_targets()
		draw_main_fixture()
	}
	rl.EndDrawing()

	when rl.RENDER_STATS_ENABLED {
		@(static) reported := false
		if !reported {
			stats := rl.renderer_stats()
			if stats.frame_index > 0 {
				fmt.println("renderer fixture baseline:", stats)
				reported = true
			}
		}
	}
}

ensure_resources :: proc() {
	if resources_ready do return
	if !font_ready {
		font = rl.LoadFontFromMemory(
			".ttf",
			raw_data(FONT_TTF),
			i32(len(FONT_TTF)),
			20,
			raw_data(FIXTURE_CPS[:]),
			i32(len(FIXTURE_CPS)),
		)
		font_ready = font.glyphCount > 0
	}

	pixels := [16]u8{
		255, 255, 255, 255, 255, 80, 80, 255,
		80, 220, 120, 255, 80, 120, 255, 255,
	}
	image := rl.Image{
		data = raw_data(pixels[:]),
		width = 2,
		height = 2,
		mipmaps = 1,
		format = .UNCOMPRESSED_R8G8B8A8,
	}
	source_texture = rl.LoadTextureFromImage(image)
	primary_rt = rl.LoadRenderTexture(256, 160)
	ping_rt = rl.LoadRenderTexture(128, 80)
	pong_rt = rl.LoadRenderTexture(128, 80)
	resources_ready = font_ready && source_texture.id != 0 &&
		primary_rt.texture.id != 0 && ping_rt.texture.id != 0 && pong_rt.texture.id != 0
}

draw_render_targets :: proc() {
	rl.BeginTextureMode(primary_rt)
	rl.ClearBackground(rl.Color{12, 16, 28, 255})
	rl.DrawRectangle(8, 8, 240, 144, rl.Color{38, 50, 82, 255})
	rl.DrawTriangle({24, 136}, {128, 20}, {232, 136}, rl.Color{250, 175, 65, 255})
	rl.BeginScissorMode(96, 48, 64, 64)
	rl.DrawCircle(128, 80, 54, rl.Color{90, 210, 150, 220})
	rl.EndScissorMode()
	rl.DrawTexturePro(
		source_texture,
		{0, 0, 2, 2},
		{176, 16, 64, 64},
		{0, 0},
		0,
		rl.WHITE,
	)
	rl.EndTextureMode()

	rl.BeginTextureMode(ping_rt)
	rl.ClearBackground(rl.BLANK)
	rl.DrawTexturePro(
		primary_rt.texture,
		{0, 0, 256, 160},
		{0, 0, 128, 80},
		{0, 0},
		0,
		rl.WHITE,
	)
	rl.EndTextureMode()

	rl.BeginTextureMode(pong_rt)
	rl.ClearBackground(rl.BLANK)
	rl.DrawTexturePro(
		ping_rt.texture,
		{0, 0, 128, 80},
		{0, 0, 128, 80},
		{0, 0},
		0,
		rl.WHITE,
	)
	rl.EndTextureMode()
}

draw_main_fixture :: proc() {
	rl.DrawRectangle(24, 24, 280, 180, rl.Color{45, 52, 72, 255})
	rl.DrawTriangle({40, 184}, {164, 40}, {288, 184}, rl.Color{238, 94, 100, 255})
	rl.DrawCircle(164, 120, 48, rl.Color{70, 185, 230, 210})

	rl.BeginScissorMode(332, 24, 280, 180)
	rl.DrawRectangle(300, 0, 360, 240, rl.Color{60, 72, 108, 255})
	rl.DrawCircle(470, 114, 120, rl.Color{235, 168, 72, 255})
	rl.EndScissorMode()

	rl.DrawTexturePro(
		primary_rt.texture,
		{0, 0, 256, -160},
		{24, 236, 384, 240},
		{0, 0},
		0,
		rl.WHITE,
	)
	rl.DrawTexturePro(
		pong_rt.texture,
		{0, 0, 128, -80},
		{432, 236, 384, 240},
		{0, 0},
		0,
		rl.WHITE,
	)

	if font_ready {
		rl.DrawTextEx(font, "FIXTURE: 2D / RT / SCISSOR", {24, 504}, 20, 1, rl.RAYWHITE)
	}
}

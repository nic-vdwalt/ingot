package main

import rl "ingot:gfx"

FONT_TTF := #load("../../assets/fonts/JetBrainsMono-Regular.ttf")

font: rl.Font
texture: rl.Texture2D
target: rl.RenderTexture2D
resources_ready: bool

main :: proc() {
	rl.SetConfigFlags({.WINDOW_RESIZABLE})
	rl.InitWindow(640, 360, "raylib migration fixture")
	rl.SetTargetFPS(60)
	font = rl.LoadFontFromMemory(".ttf", raw_data(FONT_TTF), i32(len(FONT_TTF)), 20, nil, 0)
	load_resources()
	rl.run(frame)
	when ODIN_OS != .JS {
		unload_resources()
		rl.CloseWindow()
	}
}

load_resources :: proc() {
	pixels := [16]u8{255, 255, 255, 255, 255, 100, 80, 255, 80, 210, 130, 255, 90, 130, 255, 255}
	image := rl.Image {
		data    = raw_data(pixels[:]),
		width   = 2,
		height  = 2,
		mipmaps = 1,
		format  = .UNCOMPRESSED_R8G8B8A8,
	}
	texture = rl.LoadTextureFromImage(image)
	target = rl.LoadRenderTexture(160, 90)
	resources_ready = texture.id != 0 && target.texture.id != 0 && font.glyphCount > 0
}

unload_resources :: proc() {
	if target.texture.id != 0 do rl.UnloadRenderTexture(target)
	if texture.id != 0 do rl.UnloadTexture(texture)
	if font.glyphCount > 0 do rl.UnloadFont(font)
	resources_ready = false
}

frame :: proc() {
	if resources_ready {
		rl.BeginTextureMode(target)
		rl.ClearBackground(rl.Color{24, 32, 52, 255})
		rl.DrawCircle(80, 45, 24, rl.Color{80, 210, 150, 255})
		rl.DrawTexture(texture, 16, 16, rl.WHITE)
		rl.EndTextureMode()
	}

	rl.BeginDrawing()
	rl.ClearBackground(rl.Color{18, 20, 28, 255})
	button := rl.Rectangle{24, 24, 220, 48}
	mouse := rl.GetMousePosition()
	hovered := rl.CheckCollisionPointRec(mouse, button)
	pressed := hovered && rl.IsMouseButtonPressed(.LEFT)
	color := pressed ? rl.Color{120, 180, 255, 255} : rl.Color{58, 72, 108, 255}
	rl.DrawRectangleRec(button, color)
	rl.DrawRectangleLinesEx(button, 2, rl.RAYWHITE)
	if resources_ready {
		rl.DrawTextEx(font, "raylib-shaped 2D", {38, 38}, 20, 1, rl.RAYWHITE)
		rl.DrawTexturePro(
			target.texture,
			{0, 0, 160, -90},
			{280, 24, 320, 180},
			{0, 0},
			0,
			rl.WHITE,
		)
	}
	if rl.IsKeyPressed(.SPACE) {
		rl.DrawCircle(134, 124, 18, rl.Color{255, 190, 80, 255})
	}
	rl.EndDrawing()
}

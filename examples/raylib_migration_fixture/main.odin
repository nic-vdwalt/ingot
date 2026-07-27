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
	rl.SetWindowTitle("raylib migration fixture")
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
	draw_camera_scene()
	draw_shape_surface()
	draw_default_font_text()
	rl.EndDrawing()
}

// draw_camera_scene exercises BeginMode2D/EndMode2D and the 2D camera
// coordinate helpers. Everything inside the mode is world space; the marker
// after it is screen space, so a regression that leaks the camera transform
// past EndMode2D moves the marker.
draw_camera_scene :: proc() {
	camera := rl.Camera2D {
		offset   = {120, 250},
		target   = {0, 0},
		rotation = 12,
		zoom     = 1.5,
	}
	rl.BeginMode2D(camera)
	rl.DrawRectangleRec({-30, -30, 60, 60}, rl.Color{90, 120, 200, 255})
	rl.DrawCircleV({0, 0}, 8, rl.RAYWHITE)
	rl.DrawLineEx({-40, 0}, {40, 0}, 2, rl.Color{255, 200, 120, 255})
	if resources_ready {
		rl.DrawTextPro(font, "world", {0, 20}, {0, 0}, -12, 16, 1, rl.RAYWHITE)
	}
	rl.EndMode2D()

	anchor := rl.GetWorldToScreen2D({0, 0}, camera)
	rl.DrawCircleLinesV(anchor, 14, rl.Color{255, 120, 120, 255})
	_ = rl.GetScreenToWorld2D(rl.GetMousePosition(), camera)
	_ = rl.GetCameraMatrix2D(camera)
}

// draw_shape_surface covers the 2D primitives added for raylib parity, so the
// compile gate fails if any of them regress in signature or disappear.
draw_shape_surface :: proc() {
	rl.DrawPixel(400, 240, rl.RAYWHITE)
	rl.DrawPixelV({402, 240}, rl.RAYWHITE)
	rl.DrawPoly({440, 250}, 6, 20, 0, rl.Color{200, 120, 255, 255})
	rl.DrawPolyLines({440, 250}, 6, 26, 0, rl.RAYWHITE)
	rl.DrawPolyLinesEx({440, 250}, 6, 32, 0, 2, rl.Color{120, 200, 255, 255})
	rl.DrawEllipse(520, 250, 34, 18, rl.Color{80, 210, 150, 255})
	rl.DrawEllipseLines(520, 250, 40, 24, rl.RAYWHITE)
	rl.DrawCircleSector({590, 250}, 28, 0, 140, 24, rl.Color{255, 190, 80, 255})
	rl.DrawCircleSectorLines({590, 250}, 34, 0, 140, 24, rl.RAYWHITE)

	fan := [4]rl.Vector2{{40, 300}, {80, 300}, {80, 340}, {40, 340}}
	rl.DrawTriangleFan(raw_data(fan[:]), i32(len(fan)), rl.Color{58, 72, 108, 255})
	strip := [4]rl.Vector2{{100, 300}, {100, 340}, {140, 300}, {140, 340}}
	rl.DrawTriangleStrip(raw_data(strip[:]), i32(len(strip)), rl.Color{108, 72, 58, 255})

	rl.DrawRectangleGradientEx(
		{180, 300, 90, 40},
		rl.RED,
		rl.GREEN,
		rl.BLUE,
		rl.Fade(rl.YELLOW, 0.5),
	)
	rl.DrawRectangleGradientH(280, 300, 90, 40, rl.ColorAlpha(rl.SKYBLUE, 0.8), rl.BLANK)
	rl.DrawRectangleGradientV(380, 300, 90, 40, rl.VIOLET, rl.BLANK)
	_ = rl.ColorAlphaBlend(rl.BLACK, rl.Fade(rl.WHITE, 0.5), rl.WHITE)
}

// draw_default_font_text uses the no-asset text path. It renders real glyphs
// and MeasureText returns real metrics, so the underline it draws must track
// the text it sits under.
draw_default_font_text :: proc() {
	label: cstring = "default font"
	rl.DrawText(label, 24, 360, 20, rl.RAYWHITE)
	width := rl.MeasureText(label, 20)
	rl.DrawRectangle(24, 384, width, 2, rl.Color{120, 180, 255, 255})

	if rl.IsWindowResized() {
		rl.DrawText("resized", 24, 396, 16, rl.Color{255, 190, 80, 255})
	}
	_ = rl.GetWindowPosition()
}

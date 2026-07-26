// breakout — the Phase 1 proof game: audio (synthesized via LoadSoundFromWave,
// zero asset files), gamepad + keyboard input, and the same source running
// natively and in the browser.
//
//	odin run examples/breakout -collection:ingot=.
//	bash build_web.sh examples/breakout   # then serve web/ and open it
//
// Controls: Left/Right or A/D or gamepad left stick / dpad; Space or the
// gamepad bottom face button launches the ball (and restarts after game over).
package main

import "core:fmt"
import rl "ingot:gfx"

FONT_TTF := #load("../../assets/fonts/JetBrainsMonoNerdFontMono-Regular.ttf")

SCREEN_W :: 800
SCREEN_H :: 520

BRICK_COLS :: 10
BRICK_ROWS :: 5
BRICK_W :: 72
BRICK_H :: 22
BRICK_GAP :: 6
BRICK_TOP :: 60

PADDLE_W :: 110
PADDLE_H :: 14
PADDLE_SPEED :: 520
BALL_R :: 7
BALL_SPEED :: 380

Game_Phase :: enum {
	Ready,
	Playing,
	Over,
	Won,
}

Game :: struct {
	paddle_x: f32,
	ball:     rl.Vector2,
	ball_v:   rl.Vector2,
	bricks:   [BRICK_ROWS][BRICK_COLS]bool,
	score:    i32,
	lives:    i32,
	phase:    Game_Phase,
}

font: rl.Font
game: Game
snd_paddle: rl.Sound
snd_brick: rl.Sound
snd_wall: rl.Sound
snd_lose: rl.Sound

main :: proc() {
	rl.SetConfigFlags({.VSYNC_HINT})
	rl.InitWindow(SCREEN_W, SCREEN_H, "ingot breakout")
	rl.InitAudioDevice()
	font = rl.LoadFontFromMemory(".ttf", raw_data(FONT_TTF), i32(len(FONT_TTF)), 20, nil, 0)
	snd_paddle = make_beep(440, 0.05)
	snd_brick = make_beep(660, 0.05)
	snd_wall = make_beep(220, 0.04)
	snd_lose = make_beep(110, 0.30)
	reset_game(&game)
	rl.run(frame)
}

// make_beep synthesizes a square-wave Sound — no asset files, identical on
// native and web (LoadSoundFromWave is the target-portable loader).
make_beep :: proc(freq: f32, seconds: f32) -> rl.Sound {
	RATE :: 44100
	frames := int(f32(RATE) * seconds)
	data := make([]i16, frames, context.temp_allocator)
	period := int(f32(RATE) / freq)
	if period < 2 do period = 2
	for i in 0 ..< frames {
		// Square wave with a linear fade-out to avoid the release click.
		high := (i / (period / 2)) % 2 == 0
		amp := f32(6000) * (1 - f32(i) / f32(frames))
		data[i] = i16(amp) if high else i16(-amp)
	}
	wave := rl.Wave {
		frameCount = u32(frames),
		sampleRate = RATE,
		sampleSize = 16,
		channels   = 1,
		data       = raw_data(data),
	}
	return rl.LoadSoundFromWave(wave)
}

reset_game :: proc(g: ^Game) {
	g.paddle_x = (SCREEN_W - PADDLE_W) / 2
	g.ball = {SCREEN_W / 2, SCREEN_H - 80}
	g.ball_v = {0.6 * BALL_SPEED, -0.8 * BALL_SPEED}
	for r in 0 ..< BRICK_ROWS {
		for c in 0 ..< BRICK_COLS {
			g.bricks[r][c] = true
		}
	}
	g.score = 0
	g.lives = 3
	g.phase = .Ready
}

// move_input returns -1..1 from keyboard and gamepad (stick + dpad).
move_input :: proc() -> f32 {
	dir: f32
	if rl.IsKeyDown(.LEFT) || rl.IsKeyDown(.A) do dir -= 1
	if rl.IsKeyDown(.RIGHT) || rl.IsKeyDown(.D) do dir += 1
	if rl.IsGamepadAvailable(0) {
		axis := rl.GetGamepadAxisMovement(0, .LEFT_X)
		if axis < -0.2 || axis > 0.2 do dir += axis
		if rl.IsGamepadButtonDown(0, .LEFT_FACE_LEFT) do dir -= 1
		if rl.IsGamepadButtonDown(0, .LEFT_FACE_RIGHT) do dir += 1
	}
	return clamp(dir, -1, 1)
}

action_pressed :: proc() -> bool {
	if rl.IsKeyPressed(.SPACE) do return true
	return rl.IsGamepadAvailable(0) && rl.IsGamepadButtonPressed(0, .RIGHT_FACE_DOWN)
}

update :: proc(g: ^Game, dt: f32) {
	g.paddle_x = clamp(g.paddle_x + move_input() * PADDLE_SPEED * dt, 0, SCREEN_W - PADDLE_W)

	switch g.phase {
	case .Ready:
		g.ball = {g.paddle_x + PADDLE_W / 2, SCREEN_H - 80}
		if action_pressed() do g.phase = .Playing
		return
	case .Over, .Won:
		if action_pressed() do reset_game(g)
		return
	case .Playing:
	}

	g.ball.x += g.ball_v.x * dt
	g.ball.y += g.ball_v.y * dt

	// Walls.
	if g.ball.x < BALL_R {g.ball.x = BALL_R; g.ball_v.x = -g.ball_v.x; rl.PlaySound(snd_wall)}
	if g.ball.x >
	   SCREEN_W -
		   BALL_R {g.ball.x = SCREEN_W - BALL_R; g.ball_v.x = -g.ball_v.x; rl.PlaySound(snd_wall)}
	if g.ball.y < BALL_R {g.ball.y = BALL_R; g.ball_v.y = -g.ball_v.y; rl.PlaySound(snd_wall)}

	// Paddle.
	paddle := rl.Rectangle{g.paddle_x, SCREEN_H - 40, PADDLE_W, PADDLE_H}
	if ball_hits(g.ball, paddle) && g.ball_v.y > 0 {
		g.ball_v.y = -g.ball_v.y
		// Steer by hit position: -1 (left edge) .. 1 (right edge).
		hit := (g.ball.x - (paddle.x + PADDLE_W / 2)) / (PADDLE_W / 2)
		g.ball_v.x = clamp(hit, -1, 1) * BALL_SPEED
		rl.PlaySound(snd_paddle)
	}

	// Bricks.
	remaining := 0
	brick_loop: for r in 0 ..< BRICK_ROWS {
		for c in 0 ..< BRICK_COLS {
			if !g.bricks[r][c] do continue
			remaining += 1
			if ball_hits(g.ball, brick_rect(r, c)) {
				g.bricks[r][c] = false
				g.score += 10
				g.ball_v.y = -g.ball_v.y
				remaining -= 1
				rl.PlaySound(snd_brick)
				break brick_loop
			}
		}
	}
	if remaining == 0 {
		g.phase = .Won
		return
	}

	// Bottom: lose a life.
	if g.ball.y > SCREEN_H + BALL_R {
		g.lives -= 1
		rl.PlaySound(snd_lose)
		if g.lives <= 0 {
			g.phase = .Over
		} else {
			g.phase = .Ready
			g.ball_v = {0.6 * BALL_SPEED, -0.8 * BALL_SPEED}
		}
	}
}

brick_rect :: proc(r, c: int) -> rl.Rectangle {
	x :=
		f32(c * (BRICK_W + BRICK_GAP)) +
		(SCREEN_W - BRICK_COLS * (BRICK_W + BRICK_GAP) + BRICK_GAP) / 2
	y := f32(BRICK_TOP + r * (BRICK_H + BRICK_GAP))
	return rl.Rectangle{x, y, BRICK_W, BRICK_H}
}

ball_hits :: proc(ball: rl.Vector2, rec: rl.Rectangle) -> bool {
	cx := clamp(ball.x, rec.x, rec.x + rec.width)
	cy := clamp(ball.y, rec.y, rec.y + rec.height)
	dx := ball.x - cx
	dy := ball.y - cy
	return dx * dx + dy * dy <= BALL_R * BALL_R
}

row_color :: proc(r: int) -> rl.Color {
	colors := [BRICK_ROWS]rl.Color {
		{235, 100, 100, 255},
		{235, 165, 100, 255},
		{235, 220, 100, 255},
		{130, 210, 120, 255},
		{110, 160, 235, 255},
	}
	return colors[r % BRICK_ROWS]
}

frame :: proc() {
	update(&game, rl.GetFrameTime())

	rl.BeginDrawing()
	rl.ClearBackground(rl.Color{24, 24, 30, 255})

	for r in 0 ..< BRICK_ROWS {
		for c in 0 ..< BRICK_COLS {
			if game.bricks[r][c] do rl.DrawRectangleRec(brick_rect(r, c), row_color(r))
		}
	}
	rl.DrawRectangleRec({game.paddle_x, SCREEN_H - 40, PADDLE_W, PADDLE_H}, {220, 220, 230, 255})
	rl.DrawCircleV(game.ball, BALL_R, {245, 245, 250, 255})

	hud := fmt.ctprintf("score %d   lives %d", game.score, game.lives)
	rl.DrawTextEx(font, hud, {16, 14}, 20, 1, {200, 200, 210, 255})
	if rl.IsGamepadAvailable(0) {
		rl.DrawTextEx(font, "gamepad connected", {SCREEN_W - 230, 14}, 20, 1, {130, 210, 120, 255})
	}

	switch game.phase {
	case .Ready:
		draw_center("press Space / gamepad A to launch", 300)
	case .Over:
		draw_center("game over — press Space to restart", 300)
	case .Won:
		draw_center("you win! press Space to play again", 300)
	case .Playing:
	}

	rl.EndDrawing()
	free_all(context.temp_allocator)
}

draw_center :: proc(text: cstring, y: f32) {
	size := rl.MeasureTextEx(font, text, 20, 1)
	rl.DrawTextEx(font, text, {(SCREEN_W - size.x) / 2, y}, 20, 1, {235, 235, 240, 255})
}

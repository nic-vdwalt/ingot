// ingot:gfx - synthetic input seam for headless harnesses. Compiled only
// with -define:INGOT_INPUT_SIM=true (precedent: INGOT_NET_SIM); zero cost
// and absent from normal builds.
//
// Why it exists: edge queries (IsKeyPressed, IsMouseButtonPressed/Released)
// read the buffered Input struct, but held-state queries (IsKeyDown,
// IsMouseButtonDown) bypass it and ask the platform live - headless those
// always return false, which falsely trips drag-latch "missed release"
// logic. The sim maintains its own held state and input.odin's *Down
// queries consult it under `when INGOT_INPUT_SIM`.
//
// Contract: the harness drives frames itself - call SimBeginFrame() at the
// top of each simulated frame (mirrors input_poll's clear phase), then
// SimMouse/SimButton/SimKey/SimChar to stage events. Never call EndDrawing
// or input_poll (they touch the platform layer, which has no window).
package gfx

INGOT_INPUT_SIM :: #config(INGOT_INPUT_SIM, false)

when INGOT_INPUT_SIM {
	context_sim_begin_frame :: proc(ctx: ^Context) {
		assert(ctx != nil, "context_sim_begin_frame: nil context")
		for i in 0 ..< KEY_COUNT {
			ctx.inp.pressed[i] = false
			ctx.inp.released[i] = false
			ctx.inp.repeat[i] = false
		}
		ctx.inp.char_h, ctx.inp.char_t = 0, 0
		ctx.inp.key_h, ctx.inp.key_t = 0, 0
		for i in 0 ..< 8 {
			ctx.inp.mb_pressed[i] = false
			ctx.inp.mb_released[i] = false
		}
		ctx.inp.mouse_prev = ctx.inp.mouse
		ctx.inp.mouse_delta = {}
		ctx.inp.wheel = ctx.inp.wheel_pending
		ctx.inp.wheel_pending = {}
	}

	SimBeginFrame :: proc() {
		context_sim_begin_frame(default_context())
	}

	context_sim_mouse :: proc(ctx: ^Context, x, y: f32) {
		assert(ctx != nil, "context_sim_mouse: nil context")
		ctx.inp.mouse_delta.x += x - ctx.inp.mouse.x
		ctx.inp.mouse_delta.y += y - ctx.inp.mouse.y
		ctx.inp.mouse = {x, y}
	}

	SimMouse :: proc(x, y: f32) {
		context_sim_mouse(default_context(), x, y)
	}

	context_sim_button :: proc(ctx: ^Context, button: MouseButton, down: bool) {
		assert(ctx != nil, "context_sim_button: nil context")
		b := int(button)
		assert(b >= 0 && b < 8, "context_sim_button: button out of range")
		if down && !ctx.inp.mb_down[b] do ctx.inp.mb_pressed[b] = true
		if !down && ctx.inp.mb_down[b] do ctx.inp.mb_released[b] = true
		ctx.inp.mb_down[b] = down
	}

	SimButton :: proc(button: MouseButton, down: bool) {
		context_sim_button(default_context(), button, down)
	}

	context_sim_key :: proc(ctx: ^Context, key: KeyboardKey, down: bool, repeat := false) {
		assert(ctx != nil, "context_sim_key: nil context")
		i := i32(key)
		assert(i >= 0 && i < KEY_COUNT, "context_sim_key: key out of range")
		if down && !ctx.inp.key_down[i] {
			ctx.inp.pressed[i] = true
			_push_key_input(&ctx.inp, key)
		}
		if down && repeat do ctx.inp.repeat[i] = true
		if !down && ctx.inp.key_down[i] do ctx.inp.released[i] = true
		ctx.inp.key_down[i] = down
	}

	SimKey :: proc(key: KeyboardKey, down: bool, repeat := false) {
		context_sim_key(default_context(), key, down, repeat)
	}

	context_sim_char :: proc(ctx: ^Context, r: rune) {
		assert(ctx != nil, "context_sim_char: nil context")
		_push_char_input(&ctx.inp, r)
	}

	SimChar :: proc(r: rune) {
		context_sim_char(default_context(), r)
	}

	context_sim_wheel :: proc(ctx: ^Context, dx, dy: f32) {
		assert(ctx != nil, "context_sim_wheel: nil context")
		ctx.inp.wheel.x += dx
		ctx.inp.wheel.y += dy
	}

	SimWheel :: proc(dx, dy: f32) {
		context_sim_wheel(default_context(), dx, dy)
	}

	context_sim_reset :: proc(ctx: ^Context) {
		assert(ctx != nil, "context_sim_reset: nil context")
		ctx.inp = {}
	}

	SimReset :: proc() {
		context_sim_reset(default_context())
	}
}

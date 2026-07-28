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
	@(private)
	Sim_State :: struct {
		key_down: [KEY_COUNT]bool,
		mb_down:  [8]bool,
	}
	@(private)
	g_sim: Sim_State

	// SimBeginFrame clears per-frame edges and promotes pending wheel,
	// exactly like input_poll's clear phase but without any platform call.
	// Held state (key_down / mb_down) persists across frames.
	SimBeginFrame :: proc() {
		for i in 0 ..< KEY_COUNT {
			g.inp.pressed[i] = false
			g.inp.released[i] = false
			g.inp.repeat[i] = false
		}
		g.inp.char_h, g.inp.char_t = 0, 0
		g.inp.key_h, g.inp.key_t = 0, 0
		for i in 0 ..< 8 {
			g.inp.mb_pressed[i] = false
			g.inp.mb_released[i] = false
		}
		g.inp.mouse_prev = g.inp.mouse
		g.inp.mouse_delta = {}
		g.inp.wheel = g.inp.wheel_pending
		g.inp.wheel_pending = {}
	}

	// SimMouse moves the cursor; delta accumulates within the frame.
	SimMouse :: proc(x, y: f32) {
		g.inp.mouse_delta.x += x - g.inp.mouse.x
		g.inp.mouse_delta.y += y - g.inp.mouse.y
		g.inp.mouse = {x, y}
	}

	// SimButton transitions a button and derives the press/release edge.
	// Idempotent per state: setting an already-down button down again does
	// not produce a second pressed edge (matches GLFW behaviour).
	SimButton :: proc(button: MouseButton, down: bool) {
		b := int(button)
		assert(b >= 0 && b < 8, "SimButton: button out of range")
		if down && !g_sim.mb_down[b] do g.inp.mb_pressed[b] = true
		if !down && g_sim.mb_down[b] do g.inp.mb_released[b] = true
		g_sim.mb_down[b] = down
	}

	// SimKey transitions a key and derives edges; `repeat` marks an
	// additional repeat edge on an already-held key.
	SimKey :: proc(key: KeyboardKey, down: bool, repeat := false) {
		i := i32(key)
		assert(i >= 0 && i < KEY_COUNT, "SimKey: key out of range")
		if down && !g_sim.key_down[i] {
			g.inp.pressed[i] = true
			_push_key(key)
		}
		if down && repeat do g.inp.repeat[i] = true
		if !down && g_sim.key_down[i] do g.inp.released[i] = true
		g_sim.key_down[i] = down
	}

	// SimChar stages a typed character (text input path).
	SimChar :: proc(r: rune) {
		_push_char(r)
	}

	// SimWheel stages scroll for this frame (visible immediately, unlike
	// the real pending buffer - harness frames are already discrete).
	SimWheel :: proc(dx, dy: f32) {
		g.inp.wheel.x += dx
		g.inp.wheel.y += dy
	}

	// SimReset clears all input state (teardown between fuzz rounds).
	SimReset :: proc() {
		g_sim = {}
		g.inp = {}
	}

	@(private)
	sim_key_down :: proc(i: i32) -> bool {
		if i < 0 || i >= KEY_COUNT do return false
		return g_sim.key_down[i]
	}

	@(private)
	sim_mouse_button_down :: proc(b: i32) -> bool {
		if b < 0 || b >= 8 do return false
		return g_sim.mb_down[b]
	}
}

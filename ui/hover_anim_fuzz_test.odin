#+build !js
package ui

// Stress-fuzzes the hover fade map through the headless hover_anim_step seam:
// geometry churn drives the 256-entry cap/clear and key-collision paths that
// manual hovering never reaches. Fixed seed keeps CI deterministic.

import "core:testing"
import "ingot:testx"

@(test)
fuzz_hover_anim_churn :: proc(t: ^testing.T) {
	p := testx.prng_make(0x7)
	state: map[u64]f32
	defer delete(state)
	for _ in 0 ..< 10_000 {
		// Narrow coordinate range on purpose: forces key reuse + collisions.
		x := i32(testx.int_range(&p, -64, 512))
		y := i32(testx.int_range(&p, -64, 512))
		w := i32(testx.int_range(&p, 1, 96))
		h := i32(testx.int_range(&p, 1, 96))
		hovered := testx.next_u64(&p) % 2 == 0
		dt := f32(testx.int_range(&p, 0, 250)) / 1000.0
		if testx.int_range(&p, 0, 50) == 0 do dt = 1e6 // hostile frame spike
		frac := hover_anim_step(&state, hover_anim_key(x, y, w, h), hovered, dt)
		testing.expect(t, frac >= 0 && frac <= 1, "hover fraction out of range")
		testing.expect(t, len(state) <= HOVER_ANIM_MAX, "hover map exceeded cap")
	}
	for _, v in state {
		testing.expect(t, v > 0 && v <= 1, "stored fade outside (0, 1]")
	}
}

@(test)
fuzz_hover_anim_lifecycle :: proc(t: ^testing.T) {
	state: map[u64]f32
	defer delete(state)

	// Cap: crossing HOVER_ANIM_MAX distinct keys triggers the full clear.
	saw_clear := false
	for i in 0 ..< HOVER_ANIM_MAX + 8 {
		before := len(state)
		hover_anim_step(&state, u64(i) * 0x9E37_79B9_7F4A_7C15 | 1, true, 1.0 / 60.0)
		if len(state) <= before && before >= HOVER_ANIM_MAX do saw_clear = true
		testing.expect(t, len(state) <= HOVER_ANIM_MAX, "cap breached during churn")
	}
	testing.expect(t, saw_clear, "cap clear never fired")

	// Steady-state miss: not-hovered + absent key returns 0, inserts nothing.
	clear(&state)
	frac := hover_anim_step(&state, 0xDEAD, false, 1.0 / 60.0)
	testing.expect(t, frac == 0 && len(state) == 0, "steady-state miss populated the map")

	// Fade in converges to 1; fade out converges to 0 and deletes the key.
	key := hover_anim_key(10, 20, 30, 40)
	settled := false
	for _ in 0 ..< 1_000 {
		if hover_anim_step(&state, key, true, 1.0 / 60.0) == 1 {
			settled = true
			break
		}
	}
	testing.expect(t, settled, "hover fade-in failed to converge")
	settled = false
	for _ in 0 ..< 1_000 {
		if hover_anim_step(&state, key, false, 1.0 / 60.0) == 0 {
			settled = true
			break
		}
	}
	testing.expect(t, settled, "hover fade-out failed to converge")
	testing.expect(t, key not_in state, "settled fade-out left a stale entry")
}

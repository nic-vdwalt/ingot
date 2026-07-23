#+build !js
package ui

import "core:testing"
import "ingot:testx"

@(test)
fuzz_hover_anim_bounds :: proc(t: ^testing.T) {
	p := testx.prng_make(0x7)
	state: f32
	for _ in 0 ..< 10_000 {
		hovered := testx.next_u64(&p) % 2 == 0
		dt := f32(testx.int_range(&p, 0, 250)) / 1000.0
		if testx.int_range(&p, 0, 50) == 0 do dt = 1e6
		frac := hover_anim_step(&state, hovered, dt)
		testing.expect(t, frac >= 0 && frac <= 1, "hover fraction out of range")
	}
}

@(test)
fuzz_hover_anim_lifecycle :: proc(t: ^testing.T) {
	state: f32
	settled := false
	for _ in 0 ..< 1_000 {
		if hover_anim_step(&state, true, 1.0 / 60.0) == 1 {
			settled = true
			break
		}
	}
	testing.expect(t, settled, "hover fade-in failed to converge")
	settled = false
	for _ in 0 ..< 1_000 {
		if hover_anim_step(&state, false, 1.0 / 60.0) == 0 {
			settled = true
			break
		}
	}
	testing.expect(t, settled, "hover fade-out failed to converge")
}

@(test)
button_states_are_independent_of_geometry :: proc(t: ^testing.T) {
	a, b: f32
	hover_anim_step(&a, true, 1.0 / 60.0)
	hover_anim_step(&b, false, 1.0 / 60.0)
	testing.expect(t, a > 0, "hovered button did not advance")
	testing.expect_value(t, b, f32(0))
}

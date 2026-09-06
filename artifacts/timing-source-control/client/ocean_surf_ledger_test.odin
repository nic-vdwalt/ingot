package main

import shared "../shared"
import "core:math"
import "core:testing"

@(test)
ocean_surf_ledger_accounts_clipping_and_natural_backpressure :: proc(t: ^testing.T) {
	previous_scale := debug_ocean_fixture_time_scale
	defer debug_ocean_fixture_time_scale = previous_scale
	intervals := [6]f32{0.099999, 0.1, 0.100001, 0.5, 1, 0.016666667}
	for interval in intervals {
		renderer := new(Ocean_Renderer)
		world := new(shared.World)
		ocean_surf_fixture_init(&renderer.nearshore, {0, 0, 1}, .Deep)
		for &cell in renderer.nearshore.state do cell.momentum_x = cell.depth * 10000
		for iteration in 0 ..< 20 {
			debug_ocean_fixture_time_scale = 1
			_ = ocean_surf_advance(renderer, world, {}, interval)
			ledger := renderer.surf_ledger
			accounted := f64(renderer.macro.step_count) * f64(OCEAN_WAVE_FIXED_DT) + f64(renderer.macro.accumulator) + ledger.clip_rejected + ledger.cap_rejected
			testing.expect(t, math.abs(ledger.eligible_scaled - accounted) < 0.00001)
			testing.expect(t, math.abs(f64(renderer.surf_dropped_time) - ledger.clip_rejected - ledger.cap_rejected) < 0.00001)
			testing.expect(t, renderer.macro.accumulator <= 0.5)
			testing.expect(t, renderer.nearshore.time_backlog <= 0.5)
			testing.expect_value(t, renderer.nearshore.dropped_time, f32(0))
			if iteration == 10 {
				state := renderer.nearshore.state
				pending := renderer.nearshore.pending_state
				debug_ocean_fixture_time_scale = 0
				testing.expect_value(t, ocean_surf_advance(renderer, world, {}, 10), 0)
				testing.expect_value(t, renderer.surf_ledger, ledger)
				testing.expect_value(t, renderer.nearshore.state, state)
				testing.expect_value(t, renderer.nearshore.pending_state, pending)
			}
		}
		free(world)
		free(renderer)
	}
}

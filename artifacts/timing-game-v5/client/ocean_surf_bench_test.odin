package main

import shared "../shared"
import "core:testing"
import "core:time"
import "core:fmt"

@(test)
ocean_surf_active_cost_probe :: proc(t: ^testing.T) {
	when !BENCH_ENABLED { return }
	previous_scale := debug_ocean_fixture_time_scale
	defer debug_ocean_fixture_time_scale = previous_scale
	debug_ocean_fixture_time_scale = 1
	kinds := [2]Ocean_Surf_Fixture{.Bank, .Reef}
	for kind in kinds {
		value := new(Client_State)
		mesh := new(Ocean_Fixture_Renderer)
		testing.expect(t, shared.world_init_seed(&value.world, shared.TERRAIN_SEED))
		testing.expect(t, cosmetics_init(&value.cosmetics))
		renderer := &value.terrain.ocean
		ocean_surf_fixture_init(&renderer.nearshore, {0, 0, 1}, kind)
		testing.expect(t, surfboard_spawn(value, {0, 0, 1080}, {0, 0, 1}, {1, 0, 0}))
		renderer.debug_pulse = {id = OCEAN_DEBUG_TEST_PULSE_ID, center = {0, 0, 1080}, direction = renderer.nearshore.east, significant_height = 2, period = 8, front_speed = 0.25, envelope_length = 100, envelope_width = 80, band = 100}
		renderer.debug_pulse_active = true
		for _ in 0 ..< 1800 {
			_ = ocean_surf_advance(renderer, &value.world, {}, OCEAN_WAVE_FIXED_DT, value)
			if renderer.breakers.front_count > 0 do break
		}
		testing.expect(t, renderer.breakers.front_count > 0)
		scheduler, geometry: [240]f64
		active_samples, completions := 0, 0
		for index in 0 ..< len(scheduler) {
			start := time.tick_now()
			completions += ocean_surf_advance(renderer, &value.world, {}, OCEAN_WAVE_FIXED_DT, value)
			scheduler[index] = time.duration_milliseconds(time.tick_since(start))
			start = time.tick_now()
			ocean_fixture_mesh_fill(mesh, &renderer.nearshore)
			geometry[index] = time.duration_milliseconds(time.tick_since(start))
			if renderer.breakers.front_count > 0 do active_samples += 1
		}
		measurements := [2]^[240]f64{&scheduler, &geometry}
		for samples in measurements {
			for index in 1 ..< len(samples^) {
				cursor := index
				for cursor > 0 && samples[cursor] < samples[cursor - 1] {
					samples[cursor], samples[cursor - 1] = samples[cursor - 1], samples[cursor]
					cursor -= 1
				}
			}
		}
		fmt.printf("[surf-active] %v samples=240 active=%d completions=%d scheduler median/p95/max=%.3f/%.3f/%.3f ms mesh=%.3f/%.3f/%.3f ms events=%d staging=%d bytes\n", kind, active_samples, completions, scheduler[120], scheduler[227], scheduler[239], geometry[120], geometry[227], geometry[239], size_of(Ocean_Surf_Events), size_of(renderer.nearshore.pending_state) + size_of(renderer.nearshore.pending_foam))
		testing.expect(t, active_samples > 0)
		surfboard_deinit(value)
		cosmetics_deinit(&value.cosmetics)
		shared.world_deinit(&value.world)
		free(mesh)
		free(value)
	}
}

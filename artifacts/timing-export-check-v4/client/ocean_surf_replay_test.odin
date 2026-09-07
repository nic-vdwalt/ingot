package main

import shared "../shared"
import "core:testing"
import b3 "vendor:box3d"

Ocean_Surf_Replay_Check :: struct {
	test: ^testing.T,
	reference: ^Client_State,
	observed: int,
	active_fronts: bool,
}

ocean_surf_replay_compare :: proc(value: ^Client_State, opaque: rawptr) {
	check := cast(^Ocean_Surf_Replay_Check)opaque
	reference := check.reference
	scale := debug_ocean_fixture_time_scale
	debug_ocean_fixture_time_scale = 1
	_ = ocean_surf_advance(&reference.terrain.ocean, &reference.world, {}, OCEAN_WAVE_FIXED_DT, reference)
	debug_ocean_fixture_time_scale = scale
	first, second := &reference.terrain.ocean, &value.terrain.ocean
	t := check.test
	testing.expect_value(t, first.macro.step_count, second.macro.step_count)
	testing.expect_value(t, first.nearshore.state, second.nearshore.state)
	testing.expect_value(t, first.nearshore.foam, second.nearshore.foam)
	testing.expect_value(t, first.debug_pulse, second.debug_pulse)
	testing.expect_value(t, first.debug_pulse_active, second.debug_pulse_active)
	testing.expect_value(t, first.breakers.fronts, second.breakers.fronts)
	testing.expect_value(t, first.breakers.spray, second.breakers.spray)
	testing.expect_value(t, first.breakers.emitted_cycles, second.breakers.emitted_cycles)
	testing.expect_value(t, first.breakers.debug_impact_crests, second.breakers.debug_impact_crests)
	testing.expect_value(t, first.breakers.debug_impact_valid, second.breakers.debug_impact_valid)
	testing.expect_value(t, first.surf_events.journal, second.surf_events.journal)
	testing.expect_value(t, b3.Body_GetTransform(reference.surfboard.body), b3.Body_GetTransform(value.surfboard.body))
	testing.expect_value(t, b3.Body_GetLinearVelocity(reference.surfboard.body), b3.Body_GetLinearVelocity(value.surfboard.body))
	testing.expect_value(t, b3.Body_GetAngularVelocity(reference.surfboard.body), b3.Body_GetAngularVelocity(value.surfboard.body))
	testing.expect_value(t, reference.surfboard.fixture_physics.surfables[0].point_state, value.surfboard.fixture_physics.surfables[0].point_state)
	check.observed += 1
	check.active_fronts = check.active_fronts || second.breakers.front_count > 0
}

@(test)
ocean_surf_changing_input_replay_matches_every_tick :: proc(t: ^testing.T) {
	previous_scale := debug_ocean_fixture_time_scale
	defer debug_ocean_fixture_time_scale = previous_scale
	for schedule in 0 ..< 5 {
		clients := [2]^Client_State{new(Client_State), new(Client_State)}
		for value in clients {
			testing.expect(t, shared.world_init_seed(&value.world, shared.TERRAIN_SEED))
			testing.expect(t, cosmetics_init(&value.cosmetics))
			renderer := &value.terrain.ocean
			ocean_surf_fixture_init(&renderer.nearshore, {0, 0, 1}, .Bank)
			testing.expect(t, surfboard_spawn(value, {0, 0, 1080}, {0, 0, 1}, {1, 0, 0}))
			packet := Ocean_Render_Packet{id = OCEAN_DEBUG_TEST_PULSE_ID, center = {0, 0, 1080}, direction = renderer.nearshore.east, significant_height = 2, period = 8, front_speed = 0.25, envelope_length = 100, envelope_width = 80, band = 100}
			events := [8]Ocean_Surf_Event{
				{target_tick = 1, kind = .Source_Set, packet = packet},
				{target_tick = 13, kind = .Control, control = {0.2, -0.1}},
				{target_tick = 41, kind = .Control, control = {-0.1, 0.3}},
				{target_tick = 71, kind = .Source_Set, packet = packet},
				{target_tick = 91, kind = .Control},
				{target_tick = 101, kind = .Source_Stop},
				{target_tick = 121, kind = .Source_Set, packet = packet},
				{target_tick = 151, kind = .Control, control = {0.1, 0.1}},
			}
			for event in events do testing.expect(t, ocean_surf_event_submit(&renderer.surf_events, 0, event))
		}
		check := Ocean_Surf_Replay_Check{test = t, reference = clients[0]}
		value := clients[1]
		for frame in 0 ..< 540 {
			debug_ocean_fixture_time_scale = 1
			intervals := [4]f32{OCEAN_WAVE_FIXED_DT, OCEAN_WAVE_FIXED_DT, 0, 0}
			switch schedule {
			case 1: intervals = {OCEAN_WAVE_FIXED_DT * 2, 0, 0, 0}
			case 2: intervals = {OCEAN_WAVE_FIXED_DT * 0.5, OCEAN_WAVE_FIXED_DT * 0.5, OCEAN_WAVE_FIXED_DT * 0.5, OCEAN_WAVE_FIXED_DT * 0.5}
			case 3: intervals = {OCEAN_WAVE_FIXED_DT * 0.5, OCEAN_WAVE_FIXED_DT * 1.5, 0, 0}
			case 4: intervals = {OCEAN_WAVE_FIXED_DT * 2, OCEAN_WAVE_FIXED_DT * 2, 0, 0}
			}
			if frame == 50 {
				debug_ocean_fixture_time_scale = 0
				testing.expect_value(t, ocean_surf_advance(&value.terrain.ocean, &value.world, {}, 1, value), 0)
			}
			for interval in intervals {
				debug_ocean_fixture_time_scale = 0.5 if schedule == 4 else 1
				_ = ocean_surf_advance(&value.terrain.ocean, &value.world, {}, interval, value, ocean_surf_replay_compare, &check)
			}
		}
		testing.expect_value(t, check.observed, 1080)
		testing.expect(t, check.active_fronts)
		for client in clients {
			surfboard_deinit(client)
			cosmetics_deinit(&client.cosmetics)
			shared.world_deinit(&client.world)
			free(client)
		}
	}
}

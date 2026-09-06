package main

import "core:os"
import "core:fmt"
import shared "../shared"
import "core:strconv"
import "core:strings"
import rl "ingot:gfx"

Profile_Scenario :: struct {
	initialized: bool,
	active: bool,
	name: string,
	phase: string,
	last_published: f64,
	started: f64,
	warmup: f64,
	duration: f64,
	fixed: bool,
	scale: f32,
	initial_target: [3]f32,
	initial_east: [3]f32,
	last_edit: i32,
}

profile_env_number :: proc(name: string, fallback: f64) -> f64 {
	text := os.get_env(name, context.temp_allocator)
	if len(text) == 0 do return fallback
	value, ok := strconv.parse_f64(text)
	return value if ok else fallback
}

profile_scenario_seed :: proc(fallback: u64) -> u64 {
	when PROFILE_ENABLED {
		if os.get_env("FORGE_SCENARIO", context.temp_allocator) == "" do return fallback
		text := os.get_env("FORGE_PROFILE_SEED", context.temp_allocator)
		value, ok := strconv.parse_u64(text)
		if ok do return value
	}
	return fallback
}

profile_scenario_frame :: proc(value: ^Client_State) {
	assert(value != nil, "profile_scenario_frame: nil state")
	when PROFILE_ENABLED {
		scenario := &value.profile_scenario
		if !scenario.initialized {
			scenario.initialized = true
			name := os.get_env("FORGE_SCENARIO", context.temp_allocator)
			if name != "cold-load" && name != "idle" && name != "streaming" && name != "terrain-edit" && name != "ocean" do return
			scenario.name = strings.clone(name)
			scenario.active = true
			scenario.started = rl.GetTime()
			scenario.warmup = clamp(profile_env_number("FORGE_PROFILE_WARMUP", 5), 0, 300)
			scenario.duration = clamp(profile_env_number("FORGE_PROFILE_SECONDS", 20), 1, 600)
			scenario.fixed = os.get_env("FORGE_PROFILE_QUALITY", context.temp_allocator) == "fixed"
			scenario.scale = f32(clamp(profile_env_number("FORGE_PROFILE_SCALE", 1), 0.75, 1))
			scenario.initial_target = value.orbit.target
			scenario.initial_east = value.camera_frame_east
			if scenario.name == "ocean" {
				value.orbit.distance = 120
				best_height := f32(1e9)
				best: shared.Planet_Coord
				for face in 0 ..< shared.PLANET_FACE_COUNT {
					for grid_y in 0 ..< 8 {
						for grid_x in 0 ..< 8 {
							coord := shared.Planet_Coord{cast(type_of(best.face))face, i32(grid_x * 96 + 48), i32(grid_y * 96 + 48)}
							height := shared.terrain_height_at_coord(&value.world, coord)
							if height < best_height { best_height = height; best = coord }
						}
					}
				}
				value.orbit.target = shared.planet_position(shared.planet_direction(best), best_height)
			}
			rl.SetWindowSize(i32(clamp(profile_env_number("FORGE_PROFILE_WIDTH", 1280), 320, 7680)), i32(clamp(profile_env_number("FORGE_PROFILE_HEIGHT", 720), 240, 4320)))
		}
		if !scenario.active do return
		value.performance.fixed_quality = scenario.fixed
		if scenario.fixed do value.performance.render_scale = scenario.scale
		elapsed := max(rl.GetTime() - scenario.started - scenario.warmup, 0)
		if scenario.name == "streaming" {
			value.orbit.target, value.camera_frame_east = camera_spherical_pan_next(scenario.initial_target, scenario.initial_east, value.orbit.yaw, {1, 0}, value.orbit.distance, f32(elapsed))
		}
		camera_apply_seated(value, 1.0 / 60)
		if scenario.name == "terrain-edit" && elapsed >= 1 {
			step := min(i32(elapsed * 4), 20)
			for scenario.last_edit < step {
				scenario.last_edit += 1
				value.sculpt_face = .Pos_X
				value.sculpt_x = 384
				value.sculpt_y = 384
				_ = _terraform_apply(value, -1)
			}
		}
		if elapsed >= scenario.duration {
			capture_path := os.get_env("FORGE_PROFILE_CAPTURE", context.temp_allocator)
			if len(capture_path) > 0 {
				captured := rl.SaveRenderTexturePng(value.target.texture, capture_path)
				fmt.printf("Profile scene capture: %s success=%v\n", capture_path, captured)
			}
			scenario.active = false
			value.quit_requested = true
		}
	}
}

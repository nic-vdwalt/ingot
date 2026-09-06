package main

import shared "../shared"
import "core:math"
import "core:testing"
import ecs "ingot:ecs"
import procgen "ingot:procgen"

fauna_test_tangent :: proc(coord: shared.Planet_Coord, du, dv: i32) -> [3]f32 {
	anchor := shared.planet_direction(coord)
	neighbour := shared.planet_direction(shared.planet_neighbour(coord, du, dv))
	tangent := neighbour - anchor
	tangent -= anchor * (tangent.x * anchor.x + tangent.y * anchor.y + tangent.z * anchor.z)
	return tangent / math.sqrt(tangent.x * tangent.x + tangent.y * tangent.y + tangent.z * tangent.z)
}

fauna_test_forward :: proc(transform: ^shared.Transform, movement: ^shared.Movement) -> [3]f32 {
	forward := fauna_transform(transform, movement) * [4]f32{1, 0, 0, 0}
	return forward.xyz
}

@(test)
fauna_transform_places_model_on_surface_and_faces_heading :: proc(t: ^testing.T) {
	prior := shared.Planet_Coord{.Pos_X, 384, 384}
	destination := shared.planet_neighbour(prior, 1, 0)
	transform := shared.planet_transform_make(prior, 0)
	movement := shared.Movement {
		heading_east = shared.PLANET_VECTOR_SCALE,
		prior = prior,
		destination = destination,
	}
	expected_forward := fauna_test_tangent(prior, 1, 0)
	model_transform := fauna_transform(&transform, &movement)
	origin := model_transform * [4]f32{0, 0, 0, 1}
	forward := model_transform * [4]f32{1, 0, 0, 0}
	left := model_transform * [4]f32{0, 1, 0, 0}
	up := model_transform * [4]f32{0, 0, 1, 0}
	testing.expect_value(t, origin.xyz, transform.position)
	testing.expect(t, math.abs(forward.x - expected_forward.x) < 0.000001)
	testing.expect(t, math.abs(forward.y - expected_forward.y) < 0.000001)
	testing.expect(t, math.abs(forward.z - expected_forward.z) < 0.000001)
	testing.expect_value(t, left.xyz, _camera_cross(transform.up, expected_forward))
	testing.expect_value(t, up.xyz, transform.up)
}

@(test)
fauna_transform_combines_grid_heading_components :: proc(t: ^testing.T) {
	coord := shared.Planet_Coord{.Pos_X, 384, 384}
	transform := shared.planet_transform_make(coord, 0)
	movement := shared.Movement {
		heading_east = 600_000,
		heading_north = 800_000,
		prior = coord,
		destination = coord,
	}
	expected := fauna_test_tangent(coord, 1, 0) * 0.6 + fauna_test_tangent(coord, 0, 1) * 0.8
	expected /= math.sqrt(expected.x * expected.x + expected.y * expected.y + expected.z * expected.z)
	forward := fauna_test_forward(&transform, &movement)
	testing.expect(t, forward.x * expected.x + forward.y * expected.y + forward.z * expected.z > 0.999999)
}

@(test)
fauna_transform_grid_heading_crosses_face_seams :: proc(t: ^testing.T) {
	middle := i32(shared.PLANET_FACE_CELLS / 2)
	for face in procgen.Terrain_Face_V4 {
		cases := [?]struct { coord: shared.Planet_Coord, du, dv: i32 } {
			{{face, 0, middle}, -1, 1},
			{{face, shared.PLANET_FACE_CELLS, middle}, 1, -1},
			{{face, middle, 0}, 1, -1},
			{{face, middle, shared.PLANET_FACE_CELLS}, -1, 1},
		}
		for item in cases {
			transform := shared.planet_transform_make(item.coord, 0)
			movement := shared.Movement {
				heading_east = item.du * 707_107,
				heading_north = item.dv * 707_107,
				prior = item.coord,
				destination = shared.planet_neighbour(item.coord, item.du, item.dv),
			}
			expected := fauna_test_tangent(item.coord, item.du, item.dv)
			forward := fauna_test_forward(&transform, &movement)
			testing.expectf(
				t,
				forward.x * expected.x + forward.y * expected.y + forward.z * expected.z > 0.99,
				"face %v seam heading does not follow grid tangent",
				face,
			)
		}
	}
}

@(test)
fauna_transform_retains_heading_while_stationary_and_handles_zero :: proc(t: ^testing.T) {
	coord := shared.Planet_Coord{.Pos_X, 384, 384}
	transform := shared.planet_transform_make(coord, 0)
	movement := shared.Movement {
		heading_east = -800_000,
		heading_north = 600_000,
		prior = coord,
		destination = coord,
		behavior = .Graze,
	}
	graze := fauna_transform(&transform, &movement) * [4]f32{1, 0, 0, 0}
	movement.behavior = .Idle
	idle := fauna_transform(&transform, &movement) * [4]f32{1, 0, 0, 0}
	testing.expect_value(t, graze, idle)
	movement.heading_east = 0
	movement.heading_north = 0
	fallback := fauna_transform(&transform, &movement) * [4]f32{1, 0, 0, 0}
	testing.expect_value(t, fallback.xyz, transform.east)
}

@(test)
fauna_animation_cadence_matches_locomotion :: proc(t: ^testing.T) {
	move_seconds := f32(shared.ECOLOGY_MOVE_INTERVAL_TICKS) * f32(shared.TICK_DURATION_SECONDS)
	testing.expect_value(t, fauna_animation_time(0), f32(0))
	testing.expect_value(t, fauna_animation_time(move_seconds), FAUNA_GAIT_CYCLES_PER_MOVE)
}

@(test)
fauna_movement_presentation_interpolates_and_clamps :: proc(t: ^testing.T) {
	world := new(shared.World)
	defer free(world)
	testing.expect(t, shared.world_init(world))
	defer shared.world_deinit(world)
	prior_coord := shared.Planet_Coord{.Pos_X, 384, 384}
	destination := shared.planet_neighbour(prior_coord, 1, 0)
	movement := shared.Movement {
		heading_east   = 1,
		prior          = prior_coord,
		destination    = destination,
		next_move_tick = shared.ECOLOGY_MOVE_INTERVAL_TICKS,
	}
	transform := shared.planet_transform_make(
		destination,
		shared.terrain_height_at_coord(world, destination),
	)
	prior := shared.planet_transform_make(
		prior_coord,
		shared.terrain_height_at_coord(world, prior_coord),
	)
	start_progress := fauna_movement_progress(1, 0, movement.next_move_tick)
	middle_progress := fauna_movement_progress(
		1 + shared.ECOLOGY_MOVE_INTERVAL_TICKS / 2,
		0,
		movement.next_move_tick,
	)
	end_progress := fauna_movement_progress(
		1 + shared.ECOLOGY_MOVE_INTERVAL_TICKS,
		0,
		movement.next_move_tick,
	)
	testing.expect_value(t, start_progress, f32(0))
	testing.expect_value(t, middle_progress, f32(0.5))
	testing.expect_value(t, end_progress, f32(1))
	testing.expect_value(t, fauna_movement_progress(0, -1, movement.next_move_tick), f32(0))
	testing.expect_value(t, fauna_movement_progress(100, 1, movement.next_move_tick), f32(1))
	start := fauna_presented_transform(world, &transform, &movement, start_progress)
	middle := fauna_presented_transform(world, &transform, &movement, middle_progress)
	end := fauna_presented_transform(world, &transform, &movement, end_progress)
	testing.expect_value(t, start.position, prior.position)
	middle_direction := shared.planet_direction(prior_coord) + shared.planet_direction(destination)
	middle_direction /= math.sqrt(
		middle_direction.x * middle_direction.x +
		middle_direction.y * middle_direction.y +
		middle_direction.z * middle_direction.z,
	)
	middle_radius := math.sqrt(
		middle.position.x * middle.position.x +
		middle.position.y * middle.position.y +
		middle.position.z * middle.position.z,
	)
	testing.expect(t, math.abs(middle.up.x - middle_direction.x) < 0.000001)
	testing.expect(t, math.abs(middle.up.y - middle_direction.y) < 0.000001)
	testing.expect(t, math.abs(middle.up.z - middle_direction.z) < 0.000001)
	testing.expect(t, middle_radius >= shared.PLANET_RADIUS)
	testing.expect_value(t, end.position, transform.position)
	movement.prior = movement.destination
	idle := fauna_presented_transform(world, &transform, &movement, 0)
	testing.expect_value(t, idle, transform)
}

@(test)
fauna_draw_collect_reports_complete_population :: proc(t: ^testing.T) {
	value := new(Client_State)
	defer free(value)
	testing.expect(t, shared.world_init(&value.world))
	defer shared.world_deinit(&value.world)
	count, ok := shared.world_populate_gazelles(&value.world)
	testing.expect(t, ok)
	counts := fauna_draw_collect(value)
	testing.expect_value(t, count, shared.GAZELLE_FOUNDER_COUNT)
	testing.expect_value(t, counts.population, shared.GAZELLE_FOUNDER_COUNT)
	testing.expect_value(t, counts.submitted, shared.GAZELLE_FOUNDER_COUNT)
	testing.expect_value(t, counts.incomplete, u32(0))
	testing.expect_value(t, counts.truncated, u32(0))
	bucket_total: u32
	for behavior in counts.buckets {
		for bucket in behavior do bucket_total += bucket
	}
	testing.expect_value(t, bucket_total, counts.submitted)
}

@(test)
fauna_ai_stats_cover_population_behavior_and_vitals :: proc(t: ^testing.T) {
	world := new(shared.World)
	defer free(world)
	testing.expect(t, shared.world_init(world))
	defer shared.world_deinit(world)
	_, ok := shared.world_populate_gazelles(world)
	testing.expect(t, ok)
	first := world.creatures.header.entities[0]
	organism, has_organism := ecs.get(&world.organisms, first)
	movement, has_movement := ecs.get(&world.movements, first)
	testing.expect(t, has_organism && has_movement)
	organism.health = 55
	organism.energy = 77
	movement.behavior = .Walk
	stats := fauna_ai_stats_collect(world)
	testing.expect_value(t, stats.population, shared.GAZELLE_FOUNDER_COUNT)
	testing.expect_value(t, stats.walk + stats.idle + stats.graze, stats.population)
	testing.expect_value(t, stats.min_health, u32(55))
	testing.expect_value(t, stats.min_energy, u64(77))
	testing.expect(t, stats.total_health >= u64(stats.min_health) * u64(stats.population))
	testing.expect(t, stats.total_energy >= stats.min_energy * u64(stats.population))
}

@(test)
fauna_debug_bounds_use_presented_creature_transform :: proc(t: ^testing.T) {
	value := new(Client_State)
	defer free(value)
	testing.expect(t, shared.world_init(&value.world))
	defer shared.world_deinit(&value.world)
	_, ok := shared.world_populate_gazelles(&value.world)
	testing.expect(t, ok)
	entity := value.world.creatures.header.entities[0]
	value.fauna.ready = true
	value.fauna.bounds = Bounds_3D{min = {-1, -0.5, 0}, max = {1, 0.5, 1.5}}
	bounds, found := debug_entity_extension_bounds(value, entity)
	testing.expect(t, found)
	testing.expect(t, bounds.max.x > bounds.min.x)
	testing.expect(t, bounds.max.y > bounds.min.y)
	testing.expect(t, bounds.max.z > bounds.min.z)
}

@(test)
fauna_nearest_gazelle_uses_current_transform :: proc(t: ^testing.T) {
	value := new(Client_State)
	defer free(value)
	testing.expect(t, shared.world_init(&value.world))
	defer shared.world_deinit(&value.world)
	_, _, empty := fauna_nearest_gazelle(&value.world, {})
	testing.expect(t, !empty)
	_, ok := shared.world_populate_gazelles(&value.world)
	testing.expect(t, ok)
	first := value.world.creatures.header.entities[0]
	transform, has_transform := ecs.get(&value.world.transforms, first)
	testing.expect(t, has_transform)
	origin := transform.position
	entity, position, found := fauna_nearest_gazelle(&value.world, origin)
	testing.expect(t, found)
	testing.expect_value(t, entity, first)
	testing.expect_value(t, position, origin)
	transform.position = {-shared.PLANET_RADIUS, 0, 0}
	entity, position, found = fauna_nearest_gazelle(&value.world, transform.position)
	testing.expect(t, found)
	testing.expect_value(t, entity, first)
	testing.expect_value(t, position, transform.position)
}

@(test)
fauna_jump_to_nearest_preserves_view_and_cancels_motion :: proc(t: ^testing.T) {
	value := new(Client_State)
	defer free(value)
	testing.expect(t, shared.world_init(&value.world))
	defer shared.world_deinit(&value.world)
	_, ok := shared.world_populate_gazelles(&value.world)
	testing.expect(t, ok)
	first := value.world.creatures.header.entities[0]
	transform, has_transform := ecs.get(&value.world.transforms, first)
	testing.expect(t, has_transform)
	value.orbit = {
		target   = transform.position,
		distance = 240,
		yaw      = 0.7,
		pitch    = 0.8,
	}
	value.camera.fovy = 45
	value.grab_pan.active = true
	value.globe_spin.speed = 2
	distance, yaw, pitch := value.orbit.distance, value.orbit.yaw, value.orbit.pitch
	testing.expect(t, fauna_jump_to_nearest(value))
	testing.expect_value(t, value.orbit.distance, distance)
	testing.expect_value(t, value.orbit.yaw, yaw)
	testing.expect_value(t, value.orbit.pitch, pitch)
	testing.expect(t, !value.grab_pan.active)
	testing.expect_value(t, value.globe_spin.speed, f32(0))
	testing.expect_value(t, value.camera.target, value.orbit.target)
	testing.expect_value(t, value.debug.target.kind, Debug_Target_Kind.Entity)
	testing.expect_value(t, value.debug.target.entity.entity, first)
	testing.expect_value(
		t,
		value.debug.selected_tab,
		debug_tab_category(.Entities),
	)
}

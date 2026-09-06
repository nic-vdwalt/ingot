package main

import shared "../shared"
import "core:fmt"
import "core:math"
import ecs "ingot:ecs"
import rl "ingot:gfx"

FAUNA_GAIT_CYCLES_PER_MOVE :: f32(1)
FAUNA_PHASE_BUCKETS :: 4
FAUNA_BEHAVIOR_COUNT :: 3

fauna_behavior_index :: proc(behavior: shared.Creature_Behavior) -> int {
	return int(behavior)
}

fauna_phase_bucket :: proc(entity: ecs.Entity) -> int {
	return int(entity.index % FAUNA_PHASE_BUCKETS)
}

fauna_phase_offset :: proc(bucket: int) -> f32 {
	return f32(bucket) / f32(FAUNA_PHASE_BUCKETS)
}

fauna_grid_heading_world :: proc(coord: shared.Planet_Coord, heading_u, heading_v: i32) -> [3]f32 {
	anchor := shared.planet_direction(coord)
	next_u := shared.planet_direction(shared.planet_neighbour(coord, 1, 0))
	next_v := shared.planet_direction(shared.planet_neighbour(coord, 0, 1))
	tangent_u := next_u - anchor
	tangent_u -= anchor * (
		tangent_u.x * anchor.x + tangent_u.y * anchor.y + tangent_u.z * anchor.z)
	tangent_u_length := math.sqrt(
		tangent_u.x * tangent_u.x + tangent_u.y * tangent_u.y + tangent_u.z * tangent_u.z,
	)
	if tangent_u_length > 0.000001 do tangent_u /= tangent_u_length
	tangent_v := next_v - anchor
	tangent_v -= anchor * (
		tangent_v.x * anchor.x + tangent_v.y * anchor.y + tangent_v.z * anchor.z)
	tangent_v_length := math.sqrt(
		tangent_v.x * tangent_v.x + tangent_v.y * tangent_v.y + tangent_v.z * tangent_v.z,
	)
	if tangent_v_length > 0.000001 do tangent_v /= tangent_v_length
	return tangent_u * f32(heading_u) + tangent_v * f32(heading_v)
}

fauna_transform :: proc(transform: ^shared.Transform, movement: ^shared.Movement) -> rl.Matrix {
	assert(transform != nil && movement != nil, "fauna transform: nil input")
	forward := transform.east
	if movement.heading_east != 0 || movement.heading_north != 0 {
		world_heading := fauna_grid_heading_world(
			movement.prior,
			movement.heading_east,
			movement.heading_north,
		)
		if movement.destination != movement.prior {
			world_heading =
				shared.planet_direction(movement.destination) -
				shared.planet_direction(movement.prior)
		}
		forward = world_heading - transform.up * (
			world_heading.x * transform.up.x +
			world_heading.y * transform.up.y +
			world_heading.z * transform.up.z)
		length := math.sqrt(forward.x * forward.x + forward.y * forward.y + forward.z * forward.z)
		if length > 0.000001 do forward /= length
	}
	left := _camera_cross(transform.up, forward)
	return(
		rl.MatrixTranslate(transform.position.x, transform.position.y, transform.position.z) *
		_frame_matrix(forward, left, transform.up) \
	)
}

fauna_movement_progress :: proc(tick: u64, accumulator: f64, next_move_tick: u64) -> f32 {
	interval := shared.ECOLOGY_MOVE_INTERVAL_TICKS
	if interval == 0 do return 1
	start_tick := u64(0)
	if next_move_tick > interval do start_tick = next_move_tick - interval
	processed_tick := u64(0)
	if tick > 0 do processed_tick = tick - 1
	continuous_tick := f64(processed_tick) + max(accumulator, 0) / shared.TICK_DURATION_SECONDS
	return f32(clamp((continuous_tick - f64(start_tick)) / f64(interval), f64(0), f64(1)))
}

fauna_animation_time :: proc(time_seconds: f32) -> f32 {
	move_seconds := f32(shared.ECOLOGY_MOVE_INTERVAL_TICKS) * f32(shared.TICK_DURATION_SECONDS)
	if move_seconds <= 0 do return 0
	return time_seconds * FAUNA_GAIT_CYCLES_PER_MOVE / move_seconds
}

fauna_presented_transform :: proc(
	world: ^shared.World,
	transform: ^shared.Transform,
	movement: ^shared.Movement,
	progress: f32,
) -> shared.Transform {
	assert(world != nil && transform != nil && movement != nil, "fauna presentation: nil input")
	presented := transform^
	if movement.prior == movement.destination do return presented
	prior_direction := shared.planet_direction(movement.prior)
	destination_direction := shared.planet_direction(movement.destination)
	amount := clamp(progress, f32(0), f32(1))
	direction := prior_direction + (destination_direction - prior_direction) * amount
	length := math.sqrt(direction.x * direction.x + direction.y * direction.y + direction.z * direction.z)
	if length > 0.000001 do direction /= length
	prior_height := shared.terrain_height_at_coord(world, movement.prior)
	destination_height := shared.terrain_height_at_coord(world, movement.destination)
	height := prior_height + (destination_height - prior_height) * amount
	presented.position = shared.planet_position(direction, height)
	presented.up, presented.east, presented.north = shared.planet_basis(direction)
	return presented
}

fauna_world_bounds :: proc(value: ^Client_State, entity: ecs.Entity) -> (Bounds_3D, bool) {
	transform, has_transform := ecs.get(&value.world.transforms, entity)
	movement, has_movement := ecs.get(&value.world.movements, entity)
	if !has_transform || !has_movement || !value.fauna.ready do return {}, false
	progress := fauna_movement_progress(value.tick, value.accumulator, movement.next_move_tick)
	presented := fauna_presented_transform(&value.world, transform, movement, progress)
	return bounds_transform(value.fauna.bounds, fauna_transform(&presented, movement)), true
}

fauna_nearest_gazelle :: proc(
	world: ^shared.World,
	origin: [3]f32,
) -> (
	entity: ecs.Entity,
	position: [3]f32,
	found: bool,
) {
	assert(world != nil, "fauna_nearest_gazelle: nil world")
	nearest_distance: f32
	for index in 0 ..< ecs.set_len(&world.creatures) {
		creature := world.creatures.items[index]
		if creature.kind != .Gazelle do continue
		candidate := world.creatures.header.entities[index]
		transform, has_transform := ecs.get(&world.transforms, candidate)
		if !has_transform do continue
		delta := transform.position - origin
		distance := delta.x * delta.x + delta.y * delta.y + delta.z * delta.z
		if !found || distance < nearest_distance {
			entity = candidate
			position = transform.position
			nearest_distance = distance
			found = true
		}
	}
	return
}

fauna_jump_to_nearest :: proc(value: ^Client_State) -> bool {
	assert(value != nil, "fauna_jump_to_nearest: nil state")
	entity, position, found := fauna_nearest_gazelle(&value.world, value.orbit.target)
	if !found do return false
	value.grab_pan.active = false
	value.globe_spin = {}
	value.orbit.target = position
	if net_id, ok := shared.world_net_id_for_entity(&value.world, entity); ok {
		value.debug.target = debug_target_entity(net_id, entity)
		value.debug.selected_tab = debug_tab_category(.Entities)
		value.debug.scroll = 0
		value.debug.scope_flash_elapsed = 0
	}
	camera_apply_seated(value, 0)
	value.status = "focused nearest gazelle"
	return true
}

Fauna_Draw_Counts :: struct {
	population: u32,
	submitted:  u32,
	incomplete: u32,
	truncated:  u32,
	buckets:    [FAUNA_BEHAVIOR_COUNT][FAUNA_PHASE_BUCKETS]u32,
}

Fauna_AI_Stats :: struct {
	population:   u32,
	walk:         u32,
	idle:         u32,
	graze:        u32,
	total_health: u64,
	min_health:   u32,
	max_health:   u32,
	total_energy: u64,
	min_energy:   u64,
	max_energy:   u64,
}

fauna_ai_stats_collect :: proc(world: ^shared.World) -> Fauna_AI_Stats {
	assert(world != nil, "fauna ai stats: nil world")
	stats: Fauna_AI_Stats
	for index in 0 ..< ecs.set_len(&world.creatures) {
		creature := world.creatures.items[index]
		if creature.kind != .Gazelle do continue
		entity := world.creatures.header.entities[index]
		organism, has_organism := ecs.get(&world.organisms, entity)
		movement, has_movement := ecs.get(&world.movements, entity)
		if !has_organism || !has_movement do continue
		stats.population += 1
		switch movement.behavior {
		case .Walk: stats.walk += 1
		case .Idle: stats.idle += 1
		case .Graze: stats.graze += 1
		}
		stats.total_health += u64(organism.health)
		stats.total_energy += organism.energy
		if stats.population == 1 {
			stats.min_health = organism.health
			stats.max_health = organism.health
			stats.min_energy = organism.energy
			stats.max_energy = organism.energy
		} else {
			stats.min_health = min(stats.min_health, organism.health)
			stats.max_health = max(stats.max_health, organism.health)
			stats.min_energy = min(stats.min_energy, organism.energy)
			stats.max_energy = max(stats.max_energy, organism.energy)
		}
	}
	return stats
}

fauna_draw_collect :: proc(value: ^Client_State) -> Fauna_Draw_Counts {
	assert(value != nil, "fauna_draw_collect: nil state")
	counts: Fauna_Draw_Counts
	counts.population = u32(ecs.set_len(&value.world.creatures))
	for index in 0 ..< ecs.set_len(&value.world.creatures) {
		entity := value.world.creatures.header.entities[index]
		creature := value.world.creatures.items[index]
		if creature.kind != .Gazelle do continue
		has_transform := ecs.has(&value.world.transforms, entity)
		movement, has_movement := ecs.get(&value.world.movements, entity)
		if !has_transform || !has_movement {
			counts.incomplete += 1
			continue
		}
		if counts.submitted >= u32(len(value.draw_transforms)) {
			counts.truncated += 1
			continue
		}
		behavior := fauna_behavior_index(movement.behavior)
		bucket := fauna_phase_bucket(entity)
		counts.buckets[behavior][bucket] += 1
		counts.submitted += 1
	}
	return counts
}

fauna_mesh_outline_draw :: proc(
	value: ^Client_State,
	pass: ^rl.Gpu_3D_Pass,
	entity: ecs.Entity,
	scale: f32,
	color: rl.Color,
) -> bool {
	creature, has_creature := ecs.get(&value.world.creatures, entity)
	movement, has_movement := ecs.get(&value.world.movements, entity)
	transform, has_transform := ecs.get(&value.world.transforms, entity)
	if !has_creature || creature.kind != .Gazelle || !has_movement || !has_transform || !value.fauna.ready {
		return false
	}
	progress := fauna_movement_progress(value.tick, value.accumulator, movement.next_move_tick)
	presented := fauna_presented_transform(&value.world, transform, movement, progress)
	clip := &value.fauna.walk
	if movement.behavior == .Idle do clip = &value.fauna.idle
	if movement.behavior == .Graze do clip = &value.fauna.graze
	phase :=
		value.cursor.time +
		fauna_phase_offset(fauna_phase_bucket(entity)) / clip.fps * f32(clip.frame_count)
	if !fauna_clip_sample(clip, phase) do return false
	matrix_value := fauna_transform(&presented, movement) * rl.MatrixScale(scale, scale, scale)
	rl.draw_gpu_mesh(pass, clip.mesh, matrix_value, {color = color, style = .Silhouette_Outline})
	return true
}

fauna_draw :: proc(value: ^Client_State, pass: ^rl.Gpu_3D_Pass) {
	assert(value != nil && pass != nil, "fauna draw: nil input")
	if !value.fauna.ready do return
	counts := fauna_draw_collect(value)
	@(static) reported: Fauna_Draw_Counts
	if counts != reported {
		fmt.eprintfln(
			"[planetforger] fauna: population=%d submitted=%d incomplete=%d truncated=%d",
			counts.population,
			counts.submitted,
			counts.incomplete,
			counts.truncated,
		)
		reported = counts
	}
	if counts.submitted == 0 do return
	material := rl.Gpu_Material {
		color  = {181, 119, 61, 255},
		style  = .Opaque,
		shader = value.atmosphere.object_shader,
	}
	for behavior in 0 ..< FAUNA_BEHAVIOR_COUNT {
		for bucket in 0 ..< FAUNA_PHASE_BUCKETS {
			count := counts.buckets[behavior][bucket]
			if count == 0 do continue
			cursor := 0
			for index in 0 ..< ecs.set_len(&value.world.creatures) {
				entity := value.world.creatures.header.entities[index]
				creature := value.world.creatures.items[index]
				if creature.kind != .Gazelle do continue
				movement, ok := ecs.get(&value.world.movements, entity)
				transform, located := ecs.get(&value.world.transforms, entity)
				if !ok || !located || fauna_behavior_index(movement.behavior) != behavior || fauna_phase_bucket(entity) != bucket do continue
				progress := fauna_movement_progress(
					value.tick,
					value.accumulator,
					movement.next_move_tick,
				)
				presented := fauna_presented_transform(&value.world, transform, movement, progress)
				value.draw_transforms[cursor] = fauna_transform(&presented, movement)
				cursor += 1
				if cursor >= int(count) do break
			}
			clip := &value.fauna.walk
			if behavior == fauna_behavior_index(.Idle) do clip = &value.fauna.idle
			if behavior == fauna_behavior_index(.Graze) do clip = &value.fauna.graze
			phase :=
				value.cursor.time + fauna_phase_offset(bucket) / clip.fps * f32(clip.frame_count)
			if fauna_clip_sample(clip, phase) {
				rl.draw_gpu_mesh_instanced(
					pass,
					clip.mesh,
					value.draw_transforms[:cursor],
					material,
				)
			}
		}
	}
}

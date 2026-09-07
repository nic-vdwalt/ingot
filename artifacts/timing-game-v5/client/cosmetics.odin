package main

import "core:math"
import "core:math/linalg"
import ecs "ingot:ecs"
import rl "ingot:gfx"
import b3 "vendor:box3d"

// Cosmetic Box3D layer: debris bursts when construction completes, and the
// efficiency mini-game stub. Strictly one-way — the sim never reads physics
// state, so nondeterministic physics can never desync the authoritative world.

COSMETIC_MAX :: 256
COSMETIC_LIFETIME :: f32(4.0)
COSMETIC_BURST_COUNT :: 12
COSMETIC_FIXED_DT :: f32(1.0 / 60.0)
COSMETIC_SUBSTEPS :: 4
COSMETIC_MAX_STEPS :: 8
COSMETIC_SURFABLE_MAX :: 32

PHYSICS_CATEGORY_TERRAIN :: u64(1 << 0)
PHYSICS_CATEGORY_DEBRIS :: u64(1 << 1)
PHYSICS_CATEGORY_ENTITY_QUERY :: u64(1 << 2)
PHYSICS_CATEGORY_FLORA_QUERY :: u64(1 << 3)
PHYSICS_CATEGORY_FLOOR :: u64(1 << 4)
PHYSICS_CATEGORY_SURFABLE :: u64(1 << 5)

BALANCE_DURATION :: f32(10)
BALANCE_PLATFORM_HALF :: f32(2.5)
BALANCE_FIXED_DT :: COSMETIC_FIXED_DT
BALANCE_SUBSTEPS :: COSMETIC_SUBSTEPS
BALANCE_MAX_STEPS :: COSMETIC_MAX_STEPS
BALANCE_MAX_TILT :: f32(0.35)
BALANCE_INPUT_DEADZONE :: f32(0.1)
BALANCE_PARTICIPATION_DEADLINE :: f32(2)
BALANCE_MIN_PARTICIPATION :: f32(0.25)
BALANCE_LOST_HEIGHT :: f32(-2)

Balance_Result :: enum u8 {
	Running,
	Succeeded,
	Failed,
}

Cosmetic_Surfable :: struct {
	body:        b3.BodyId,
	query:       Ocean_Macro_Wave_Query,
	points:      [WATER_PHYSICS_HULL_POINT_MAX]Water_Physics_Hull_Point,
	point_state: [WATER_PHYSICS_HULL_POINT_MAX]Water_Physics_Point_State,
	point_count: u8,
}

Cosmetics :: struct {
	world:          b3.WorldId,
	bodies:         [COSMETIC_MAX]b3.BodyId,
	ages:           [COSMETIC_MAX]f32,
	half_heights:   [COSMETIC_MAX]f32,
	body_count:     u32,
	water_query:    Ocean_Macro_Wave_Query,
	surfables:      [COSMETIC_SURFABLE_MAX]Cosmetic_Surfable,
	surfable_count: u32,
	accumulator:    f32,
	ready:          bool,
}

Balance_Minigame :: struct {
	world:                 b3.WorldId,
	platform:              b3.BodyId,
	payload:               b3.BodyId,
	target:                ecs.Entity,
	accumulator:           f32,
	elapsed:               f32,
	control_total:         f32,
	control_steps:         u32,
	participation_seconds: f32,
	tilt:                  [2]f32,
	result:                Balance_Result,
	active:                bool,
}

cosmetics_init :: proc(value: ^Cosmetics) -> bool {
	assert(value != nil, "cosmetics_init: nil cosmetics")
	assert(!value.ready, "cosmetics_init: already ready")
	if b3.World_IsValid(value.world) do b3.DestroyWorld(value.world)
	value^ = {}
	world_def := b3.DefaultWorldDef()
	world_def.gravity = {0, 0, -10}
	value.world = b3.CreateWorld(world_def)
	if !b3.World_IsValid(value.world) do return false
	body_def := b3.DefaultBodyDef()
	body_def.type = .staticBody
	body_def.position = {0, 0, -60}
	floor := b3.CreateBody(value.world, body_def)
	if !b3.Body_IsValid(floor) {
		cosmetics_deinit(value)
		return false
	}
	hull := b3.MakeBoxHull(200, 200, 10)
	shape_def := b3.DefaultShapeDef()
	shape_def.filter.categoryBits = PHYSICS_CATEGORY_FLOOR
	shape_def.filter.maskBits = PHYSICS_CATEGORY_DEBRIS
	shape := b3.CreateHullShape(floor, shape_def, &hull.base)
	if !b3.Shape_IsValid(shape) {
		cosmetics_deinit(value)
		return false
	}
	value.ready = true
	return true
}

// cosmetics_spawn_burst throws a handful of small cubes outward from the
// completed building. Slots are bounded; when full, the oldest debris is
// recycled so a build spree cannot exhaust the pool.
cosmetics_spawn_burst :: proc(value: ^Cosmetics, position: [3]f32) {
	assert(value != nil, "cosmetics_spawn_burst: nil cosmetics")
	if !value.ready do return
	assert(value.body_count <= COSMETIC_MAX, "cosmetics_spawn_burst: count over capacity")
	for index in 0 ..< COSMETIC_BURST_COUNT {
		if value.body_count >= COSMETIC_MAX do _cosmetic_destroy_at(value, 0)
		angle := f32(index) * (2 * 3.14159265 / f32(COSMETIC_BURST_COUNT))
		body_def := b3.DefaultBodyDef()
		body_def.type = .dynamicBody
		body_def.position = {position.x, position.y, position.z + 1.5}
		body_def.linearVelocity = {
			linalg.cos(angle) * 3,
			linalg.sin(angle) * 3,
			5 + f32(index % 3),
		}
		body_def.angularVelocity = {f32(index % 5), f32(index % 7), 1}
		body := b3.CreateBody(value.world, body_def)
		if !b3.Body_IsValid(body) do return
		shape_def := b3.DefaultShapeDef()
		shape_def.density = 1
		shape_def.filter.categoryBits = PHYSICS_CATEGORY_DEBRIS
		shape_def.filter.maskBits = PHYSICS_CATEGORY_TERRAIN | PHYSICS_CATEGORY_FLOOR
		hull := b3.MakeCubeHull(0.18)
		shape := b3.CreateHullShape(body, shape_def, &hull.base)
		if !b3.Shape_IsValid(shape) {
			b3.DestroyBody(body)
			return
		}
		value.bodies[value.body_count] = body
		value.ages[value.body_count] = 0
		value.half_heights[value.body_count] = 0.18
		value.body_count += 1
	}
}

cosmetics_register_surfable :: proc(
	value: ^Cosmetics,
	body: b3.BodyId,
	points: []Water_Physics_Hull_Point,
) -> bool {
	assert(value != nil, "cosmetics_register_surfable: nil cosmetics")
	if !value.ready || !b3.Body_IsValid(body) do return false
	if len(points) == 0 || len(points) > WATER_PHYSICS_HULL_POINT_MAX do return false
	if value.surfable_count >= COSMETIC_SURFABLE_MAX do return false
	for surfable in value.surfables[:value.surfable_count] {
		if surfable.body == body do return false
	}
	surfable := &value.surfables[value.surfable_count]
	surfable^ = {}
	surfable.body = body
	surfable.point_count = u8(len(points))
	copy(surfable.points[:], points)
	value.surfable_count += 1
	return true
}

cosmetics_unregister_surfable :: proc(value: ^Cosmetics, body: b3.BodyId) {
	assert(value != nil, "cosmetics_unregister_surfable: nil cosmetics")
	for index in 0 ..< value.surfable_count {
		if value.surfables[index].body != body do continue
		last := value.surfable_count - 1
		value.surfables[index] = value.surfables[last]
		value.surfables[last] = {}
		value.surfable_count = last
		return
	}
}

cosmetics_apply_water :: proc(value: ^Cosmetics, client: ^Client_State) {
	assert(value != nil && client != nil, "cosmetics_apply_water: nil input")
	for index in 0 ..< value.body_count {
		body := value.bodies[index]
		if !b3.Body_IsValid(body) do continue
		position := b3.Body_GetPosition(body)
		velocity := b3.Body_GetLinearVelocity(body)
		mass := b3.Body_GetMass(body)
		_ = ocean_macro_query_update(&value.water_query, &client.world, position)
		sample := world_water_physics_sample(
			client,
			&value.water_query,
			position,
			client.terrain.ocean.macro.time,
		)
		force := water_physics_force(position, value.half_heights[index], mass, velocity, sample)
		force += water_physics_acceleration_force(sample, mass)
		if force.x != 0 || force.y != 0 || force.z != 0 {
			b3.Body_ApplyForceToCenter(body, force, true)
		}
	}
}

cosmetics_apply_surfable_water :: proc(value: ^Cosmetics, client: ^Client_State, dt: f32) {
	assert(value != nil && client != nil, "cosmetics_apply_surfable_water: nil input")
	index: u32 = 0
	for index < value.surfable_count {
		surfable := &value.surfables[index]
		if !b3.Body_IsValid(surfable.body) {
			cosmetics_unregister_surfable(value, surfable.body)
			continue
		}
		transform := b3.Body_GetTransform(surfable.body)
		state := Water_Physics_Body_State {
			position         = transform.p,
			forward          = b3.Body_GetWorldVector(surfable.body, {1, 0, 0}),
			right            = b3.Body_GetWorldVector(surfable.body, {0, 1, 0}),
			up               = b3.Body_GetWorldVector(surfable.body, {0, 0, 1}),
			linear_velocity  = b3.Body_GetLinearVelocity(surfable.body),
			angular_velocity = b3.Body_GetAngularVelocity(surfable.body),
			mass             = b3.Body_GetMass(surfable.body),
		}
		_ = ocean_macro_query_update(&surfable.query, &client.world, state.position)
		sample_time := client.terrain.ocean.macro.time
		center_sample := world_water_physics_sample(
			client,
			&surfable.query,
			state.position,
			sample_time,
		)
		count := int(surfable.point_count)
		samples: [WATER_PHYSICS_HULL_POINT_MAX]Water_Physics_Sample
		loads: [WATER_PHYSICS_HULL_POINT_MAX]Water_Physics_Point_Load
		for point_index in 0 ..< count {
			position := water_physics_hull_point_position(state, surfable.points[point_index])
			samples[point_index] = world_water_physics_sample(
				client,
				&surfable.query,
				position,
				sample_time,
			)
		}
		result := water_physics_hull_step(
			state,
			surfable.points[:count],
			samples[:count],
			surfable.point_state[:count],
			dt,
			loads[:count],
		)
		for load in loads[:result.count] {
			b3.Body_ApplyForce(surfable.body, load.force, load.position, true)
		}
		gravity_force := water_physics_radial_gravity_force(
			state.position,
			state.mass,
			b3.Body_GetGravityScale(surfable.body),
			{0, 0, -WATER_PHYSICS_GRAVITY},
		)
		if gravity_force.x != 0 || gravity_force.y != 0 || gravity_force.z != 0 {
			b3.Body_ApplyForceToCenter(surfable.body, gravity_force, true)
		}
		immersion := water_physics_hull_immersion(
			surfable.points[:count],
			surfable.point_state[:count],
		)
		acceleration_force := water_physics_acceleration_force(
			center_sample,
			state.mass,
			immersion,
		)
		if acceleration_force.x != 0 || acceleration_force.y != 0 || acceleration_force.z != 0 {
			b3.Body_ApplyForceToCenter(surfable.body, acceleration_force, true)
		}
		index += 1
	}
}

cosmetics_update :: proc(value: ^Cosmetics, client: ^Client_State, frame_dt: f32) {
	assert(value != nil && client != nil, "cosmetics_update: nil input")
	assert(frame_dt >= 0, "cosmetics_update: negative frame dt")
	if !value.ready do return
	if value.body_count == 0 && value.surfable_count == 0 {
		value.accumulator = 0
		return
	}
	value.accumulator += frame_dt
	steps := 0
	for value.accumulator >= COSMETIC_FIXED_DT && steps < COSMETIC_MAX_STEPS {
		cosmetics_apply_water(value, client)
		cosmetics_apply_surfable_water(value, client, COSMETIC_FIXED_DT)
		b3.World_Step(value.world, COSMETIC_FIXED_DT, COSMETIC_SUBSTEPS)
		value.accumulator -= COSMETIC_FIXED_DT
		steps += 1
	}
	if value.accumulator > COSMETIC_FIXED_DT do value.accumulator = COSMETIC_FIXED_DT
	// Age and expire debris; swap-remove keeps the array dense. The index is
	// only advanced when the slot survives, and every iteration either
	// advances or shrinks the range, so the loop is bounded.
	index: u32 = 0
	for index < value.body_count {
		value.ages[index] += frame_dt
		if value.ages[index] >= COSMETIC_LIFETIME {
			_cosmetic_destroy_at(value, index)
			continue
		}
		index += 1
	}
}

cosmetics_draw :: proc(
	value: ^Cosmetics,
	pass: ^rl.Gpu_3D_Pass,
	cube: rl.Gpu_Mesh,
	edges: rl.Gpu_Mesh,
) {
	assert(value != nil, "cosmetics_draw: nil cosmetics")
	assert(pass != nil, "cosmetics_draw: nil pass")
	if !value.ready || value.body_count == 0 do return
	transforms: [COSMETIC_MAX]rl.Matrix
	for index in 0 ..< value.body_count {
		physics_transform := b3.Body_GetTransform(value.bodies[index])
		transforms[index] = linalg.matrix4_from_trs_f32(
			physics_transform.p,
			physics_transform.q,
			[3]f32{0.36, 0.36, 0.36},
		)
	}
	slice := transforms[:value.body_count]
	rl.draw_gpu_mesh_instanced(&pass^, cube, slice, {color = {200, 200, 210, 255}})
	rl.draw_gpu_mesh_instanced(
		&pass^,
		edges,
		slice,
		{color = {24, 28, 36, 255}, style = .Opaque_Outline},
	)
}

cosmetics_deinit :: proc(value: ^Cosmetics) {
	assert(value != nil, "cosmetics_deinit: nil cosmetics")
	if b3.World_IsValid(value.world) do b3.DestroyWorld(value.world)
	value^ = {}
}

balance_minigame_start :: proc(value: ^Balance_Minigame, target: ecs.Entity) -> bool {
	assert(value != nil, "balance_minigame_start: nil minigame")
	balance_minigame_deinit(value)
	world_def := b3.DefaultWorldDef()
	world_def.gravity = {0, 0, -10}
	value.world = b3.CreateWorld(world_def)
	if !b3.World_IsValid(value.world) do return false
	platform_def := b3.DefaultBodyDef()
	platform_def.type = .kinematicBody
	value.platform = b3.CreateBody(value.world, platform_def)
	if !b3.Body_IsValid(value.platform) {
		balance_minigame_deinit(value)
		return false
	}
	platform_hull := b3.MakeBoxHull(BALANCE_PLATFORM_HALF, BALANCE_PLATFORM_HALF, 0.2)
	platform_shape := b3.CreateHullShape(value.platform, b3.DefaultShapeDef(), &platform_hull.base)
	if !b3.Shape_IsValid(platform_shape) {
		balance_minigame_deinit(value)
		return false
	}
	payload_def := b3.DefaultBodyDef()
	payload_def.type = .dynamicBody
	payload_def.position = {0, 0, 1}
	payload_def.angularDamping = 0.3
	value.payload = b3.CreateBody(value.world, payload_def)
	if !b3.Body_IsValid(value.payload) {
		balance_minigame_deinit(value)
		return false
	}
	payload_shape_def := b3.DefaultShapeDef()
	payload_shape_def.density = 1
	payload_shape_def.baseMaterial.friction = 0.35
	payload_hull := b3.MakeCubeHull(0.35)
	payload_shape := b3.CreateHullShape(value.payload, payload_shape_def, &payload_hull.base)
	if !b3.Shape_IsValid(payload_shape) {
		balance_minigame_deinit(value)
		return false
	}
	value.target = target
	value.active = true
	return true
}

balance_minigame_update :: proc(
	value: ^Balance_Minigame,
	frame_dt: f32,
	tilt: [2]f32,
) -> Balance_Result {
	assert(value != nil, "balance_minigame_update: nil minigame")
	assert(frame_dt >= 0, "balance_minigame_update: negative frame dt")
	if !value.active do return value.result
	if value.result != .Running do return value.result
	input_active :=
		math.abs(tilt.x) > BALANCE_INPUT_DEADZONE || math.abs(tilt.y) > BALANCE_INPUT_DEADZONE
	value.tilt.x = clamp(tilt.x, -1, 1) * BALANCE_MAX_TILT
	value.tilt.y = clamp(tilt.y, -1, 1) * BALANCE_MAX_TILT
	rotation_x := b3.MakeQuatFromAxisAngle({1, 0, 0}, value.tilt.y)
	rotation_y := b3.MakeQuatFromAxisAngle({0, 1, 0}, -value.tilt.x)
	rotation := b3.MulQuat(rotation_y, rotation_x)
	b3.Body_SetTransform(value.platform, {}, rotation)
	value.accumulator += frame_dt
	steps := 0
	for value.accumulator >= BALANCE_FIXED_DT &&
	    steps < BALANCE_MAX_STEPS &&
	    value.elapsed < BALANCE_DURATION {
		b3.World_Step(value.world, BALANCE_FIXED_DT, BALANCE_SUBSTEPS)
		payload := b3.Body_GetPosition(value.payload)
		value.elapsed += BALANCE_FIXED_DT
		if input_active do value.participation_seconds += BALANCE_FIXED_DT
		if payload.z < BALANCE_LOST_HEIGHT {
			value.result = .Failed
			return value.result
		}
		distance := math.sqrt(payload.x * payload.x + payload.y * payload.y)
		control := f32(0)
		if payload.z > -0.5 && distance < BALANCE_PLATFORM_HALF {
			control = 1 - distance / BALANCE_PLATFORM_HALF
		}
		value.control_total += control
		value.control_steps += 1
		value.accumulator -= BALANCE_FIXED_DT
		steps += 1
		if value.elapsed >= BALANCE_PARTICIPATION_DEADLINE &&
		   value.participation_seconds < BALANCE_MIN_PARTICIPATION {
			value.result = .Failed
			return value.result
		}
	}
	if value.accumulator > BALANCE_FIXED_DT do value.accumulator = BALANCE_FIXED_DT
	if value.elapsed >= BALANCE_DURATION do value.result = .Succeeded
	return value.result
}

balance_minigame_score :: proc(value: ^Balance_Minigame) -> u8 {
	assert(value != nil, "balance_minigame_score: nil minigame")
	average := f32(0)
	if value.control_steps > 0 do average = value.control_total / f32(value.control_steps)
	return u8(clamp(50 + int(math.round(100 * average)), 50, 150))
}

balance_minigame_draw :: proc(
	value: ^Balance_Minigame,
	pass: ^rl.Gpu_3D_Pass,
	cube, edges: rl.Gpu_Mesh,
) {
	assert(value != nil, "balance_minigame_draw: nil minigame")
	assert(pass != nil, "balance_minigame_draw: nil pass")
	if !value.active do return
	platform_transform := b3.Body_GetTransform(value.platform)
	platform_matrix := linalg.matrix4_from_trs_f32(
		platform_transform.p,
		platform_transform.q,
		[3]f32{BALANCE_PLATFORM_HALF * 2, BALANCE_PLATFORM_HALF * 2, 0.4},
	)
	payload_transform := b3.Body_GetTransform(value.payload)
	payload_matrix := linalg.matrix4_from_trs_f32(
		payload_transform.p,
		payload_transform.q,
		[3]f32{0.7, 0.7, 0.7},
	)
	rl.draw_gpu_mesh(&pass^, cube, platform_matrix, {color = {80, 130, 180, 255}})
	rl.draw_gpu_mesh(
		&pass^,
		edges,
		platform_matrix,
		{color = {24, 28, 36, 255}, style = .Opaque_Outline},
	)
	rl.draw_gpu_mesh(&pass^, cube, payload_matrix, {color = {247, 213, 105, 255}})
	rl.draw_gpu_mesh(
		&pass^,
		edges,
		payload_matrix,
		{color = {24, 28, 36, 255}, style = .Opaque_Outline},
	)
}

balance_minigame_deinit :: proc(value: ^Balance_Minigame) {
	assert(value != nil, "balance_minigame_deinit: nil minigame")
	if b3.World_IsValid(value.world) do b3.DestroyWorld(value.world)
	value^ = {}
}

_cosmetic_destroy_at :: proc(value: ^Cosmetics, index: u32) {
	assert(value != nil, "_cosmetic_destroy_at: nil cosmetics")
	assert(index < value.body_count, "_cosmetic_destroy_at: index out of range")
	if b3.Body_IsValid(value.bodies[index]) do b3.DestroyBody(value.bodies[index])
	last := value.body_count - 1
	value.bodies[index] = value.bodies[last]
	value.ages[index] = value.ages[last]
	value.half_heights[index] = value.half_heights[last]
	value.body_count = last
}

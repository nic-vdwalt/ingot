package main

import "core:c"
import "core:math"
import "core:math/linalg"
import rl "ingot:gfx"
import b3 "vendor:box3d"

SURFBOARD_LENGTH :: f32(2.4)
SURFBOARD_WIDTH :: f32(0.62)
SURFBOARD_THICKNESS :: f32(0.09)
SURFBOARD_SPAWN_CLEARANCE :: f32(0.05)
SURFBOARD_CONTROL_TORQUE :: f32(18)
PHYSICS_CATEGORY_SURF_FIXTURE :: u64(1 << 6)

Surfboard :: struct {
	body:    b3.BodyId,
	fixture_body: b3.BodyId,
	fixture_mesh: ^b3.MeshData,
	fixture_physics: ^Cosmetics,
	active:  bool,
	visible: bool,
	control: [2]f32,
}

surfboard_hydrodynamic_points :: proc() -> [8]Water_Physics_Hull_Point {
	return {
		{
			local_position = {0.95, -0.24, -0.04},
			displacement_share = 0.10,
			area = 0.18,
			immersion_radius = 0.09,
			drag = {0.08, 1.8, 1.2},
			planing = 0.34,
			rail = 1.8,
			slamming = 0.16,
			ventilation_depth = 0.35,
		},
		{
			local_position = {0.95, 0.24, -0.04},
			displacement_share = 0.10,
			area = 0.18,
			immersion_radius = 0.09,
			drag = {0.08, 1.8, 1.2},
			planing = 0.34,
			rail = 1.8,
			slamming = 0.16,
			ventilation_depth = 0.35,
		},
		{
			local_position = {0.30, -0.27, -0.04},
			displacement_share = 0.15,
			area = 0.22,
			immersion_radius = 0.09,
			drag = {0.07, 2.2, 1.3},
			planing = 0.42,
			rail = 2.2,
			slamming = 0.18,
			ventilation_depth = 0.4,
		},
		{
			local_position = {0.30, 0.27, -0.04},
			displacement_share = 0.15,
			area = 0.22,
			immersion_radius = 0.09,
			drag = {0.07, 2.2, 1.3},
			planing = 0.42,
			rail = 2.2,
			slamming = 0.18,
			ventilation_depth = 0.4,
		},
		{
			local_position = {-0.40, -0.25, -0.04},
			displacement_share = 0.15,
			area = 0.22,
			immersion_radius = 0.09,
			drag = {0.07, 2.4, 1.35},
			planing = 0.46,
			rail = 2.4,
			fin = 1.1,
			slamming = 0.18,
			ventilation_depth = 0.45,
		},
		{
			local_position = {-0.40, 0.25, -0.04},
			displacement_share = 0.15,
			area = 0.22,
			immersion_radius = 0.09,
			drag = {0.07, 2.4, 1.35},
			planing = 0.46,
			rail = 2.4,
			fin = 1.1,
			slamming = 0.18,
			ventilation_depth = 0.45,
		},
		{
			local_position = {-1.02, -0.18, -0.04},
			displacement_share = 0.10,
			area = 0.16,
			immersion_radius = 0.09,
			drag = {0.09, 2.8, 1.5},
			planing = 0.38,
			rail = 2.6,
			fin = 1.8,
			slamming = 0.20,
			ventilation_depth = 0.5,
		},
		{
			local_position = {-1.02, 0.18, -0.04},
			displacement_share = 0.10,
			area = 0.16,
			immersion_radius = 0.09,
			drag = {0.09, 2.8, 1.5},
			planing = 0.38,
			rail = 2.6,
			fin = 1.8,
			slamming = 0.20,
			ventilation_depth = 0.5,
		},
	}
}

surfboard_spawn :: proc(
	value: ^Client_State,
	position, surface_normal, direction: [3]f32,
) -> bool {
	assert(value != nil, "surfboard_spawn: nil state")
	if !value.cosmetics.ready do return false
	up, up_ok := ocean_wave_normalize(surface_normal)
	forward, forward_ok := ocean_wave_tangent_direction(up, direction)
	if !up_ok || !forward_ok do return false
	surfboard_deinit(value)
	surfboard_fixture_boundary_reset(value)
	physics := &value.cosmetics
	fixture_physics: ^Cosmetics
	transferred := false
	if value.terrain.ocean.nearshore.fixture_active {
		fixture_physics = new(Cosmetics)
		physics = fixture_physics
	}
	defer {
		if fixture_physics != nil && !transferred {
			cosmetics_deinit(fixture_physics)
			free(fixture_physics)
		}
	}
	if fixture_physics != nil && !cosmetics_init(fixture_physics) do return false
	local_up := [3]f32{0, 0, 1}
	rotation := b3.ComputeQuatBetweenUnitVectors(local_up, up)
	rotated_forward := b3.RotateVector(rotation, [3]f32{1, 0, 0})
	turn_cosine := clamp(
		rotated_forward.x * forward.x +
		rotated_forward.y * forward.y +
		rotated_forward.z * forward.z,
		-1,
		1,
	)
	turn_sine :=
		up.x * (rotated_forward.y * forward.z - rotated_forward.z * forward.y) +
		up.y * (rotated_forward.z * forward.x - rotated_forward.x * forward.z) +
		up.z * (rotated_forward.x * forward.y - rotated_forward.y * forward.x)
	turn := math.atan2(turn_sine, turn_cosine)
	rotation = b3.MakeQuatFromAxisAngle(up, turn) * rotation
	body_def := b3.DefaultBodyDef()
	body_def.type = .dynamicBody
	body_def.position = position + up * SURFBOARD_SPAWN_CLEARANCE
	body_def.rotation = rotation
	body_def.gravityScale = 0
	body_def.angularDamping = 0.25
	body_def.enableSleep = false
	body := b3.CreateBody(physics.world, body_def)
	if !b3.Body_IsValid(body) do return false
	shape_def := b3.DefaultShapeDef()
	shape_def.density = 18
	shape_def.baseMaterial.friction = 0.24
	shape_def.filter.categoryBits = PHYSICS_CATEGORY_SURFABLE
	shape_def.filter.maskBits = PHYSICS_CATEGORY_SURF_FIXTURE if value.terrain.ocean.nearshore.fixture_active else PHYSICS_CATEGORY_TERRAIN
	hull := b3.MakeBoxHull(
		SURFBOARD_LENGTH * 0.5,
		SURFBOARD_WIDTH * 0.5,
		SURFBOARD_THICKNESS * 0.5,
	)
	shape := b3.CreateHullShape(body, shape_def, &hull.base)
	if !b3.Shape_IsValid(shape) {
		b3.DestroyBody(body)
		return false
	}
	points := surfboard_hydrodynamic_points()
	if !cosmetics_register_surfable(physics, body, points[:]) {
		b3.DestroyBody(body)
		return false
	}
	value.surfboard = {
		body    = body,
		fixture_physics = fixture_physics,
		active  = true,
		visible = true,
	}
	transferred = true
	if value.terrain.ocean.nearshore.fixture_active && !surfboard_fixture_collision_init(value) {
		surfboard_deinit(value)
		return false
	}
	return true
}

surfboard_fixture_collision_init :: proc(value: ^Client_State) -> bool {
	mesh := new(Ocean_Fixture_Renderer)
	defer free(mesh)
	ocean_fixture_mesh_fill(mesh, &value.terrain.ocean.nearshore)
	vertices := make([]b3.Vec3, len(mesh.bed_vertices))
	indices := make([]i32, len(mesh.indices))
	defer delete(vertices)
	defer delete(indices)
	for vertex, index in mesh.bed_vertices do vertices[index] = vertex.position
	for index, offset in mesh.indices do indices[offset] = i32(index)
	definition := b3.MeshDef {
		vertices = raw_data(vertices),
		indices = raw_data(indices),
		vertexCount = c.int(len(vertices)),
		triangleCount = c.int(len(indices) / 3),
		weldVertices = false,
		useMedianSplit = true,
		identifyEdges = true,
	}
	value.surfboard.fixture_mesh = b3.CreateMesh(definition, nil, 0)
	if value.surfboard.fixture_mesh == nil do return false
	body_definition := b3.DefaultBodyDef()
	body_definition.type = .staticBody
	value.surfboard.fixture_body = b3.CreateBody(value.surfboard.fixture_physics.world, body_definition)
	if !b3.Body_IsValid(value.surfboard.fixture_body) do return false
	shape_definition := b3.DefaultShapeDef()
	shape_definition.filter.categoryBits = PHYSICS_CATEGORY_SURF_FIXTURE
	shape_definition.filter.maskBits = PHYSICS_CATEGORY_SURFABLE
	shape := b3.CreateMeshShape(value.surfboard.fixture_body, shape_definition, value.surfboard.fixture_mesh, {1, 1, 1})
	return b3.Shape_IsValid(shape)
}

surfboard_update_control :: proc(value: ^Client_State, frame_dt: f32) {
	assert(value != nil, "surfboard_update_control: nil state")
	if !value.surfboard.active || !b3.Body_IsValid(value.surfboard.body) || frame_dt <= 0 do return
	pitch := f32(0)
	roll := f32(0)
	if rl.IsKeyDown(.UP) do pitch += 1
	if rl.IsKeyDown(.DOWN) do pitch -= 1
	if rl.IsKeyDown(.LEFT) do roll += 1
	if rl.IsKeyDown(.RIGHT) do roll -= 1
	surfboard_apply_control(value, {pitch, roll})
}

surfboard_apply_control :: proc(value: ^Client_State, control: [2]f32) {
	if !value.surfboard.active || !b3.Body_IsValid(value.surfboard.body) do return
	pitch := clamp(control.x, f32(-1), f32(1))
	roll := clamp(control.y, f32(-1), f32(1))
	if pitch == 0 && roll == 0 do return
	right := b3.Body_GetWorldVector(value.surfboard.body, {0, 1, 0})
	forward := b3.Body_GetWorldVector(value.surfboard.body, {1, 0, 0})
	torque := right * pitch * SURFBOARD_CONTROL_TORQUE + forward * roll * SURFBOARD_CONTROL_TORQUE
	b3.Body_ApplyTorque(value.surfboard.body, torque, true)
}

surfboard_fixture_tick :: proc(value: ^Client_State) {
	#assert(OCEAN_WAVE_FIXED_DT == COSMETIC_FIXED_DT)
	physics := value.surfboard.fixture_physics
	if physics == nil || !physics.ready do return
	surfboard_apply_control(value, value.surfboard.control)
	cosmetics_apply_surfable_water(physics, value, OCEAN_WAVE_FIXED_DT)
	b3.World_Step(physics.world, OCEAN_WAVE_FIXED_DT, COSMETIC_SUBSTEPS)
}

surfboard_draw :: proc(value: ^Client_State, pass: ^rl.Gpu_3D_Pass) {
	assert(value != nil && pass != nil, "surfboard_draw: nil input")
	if !value.surfboard.active || !value.surfboard.visible || !b3.Body_IsValid(value.surfboard.body) do return
	transform := b3.Body_GetTransform(value.surfboard.body)
	model_matrix := linalg.matrix4_from_trs_f32(
		transform.p,
		transform.q,
		[3]f32{SURFBOARD_LENGTH, SURFBOARD_WIDTH, SURFBOARD_THICKNESS},
	)
	rl.draw_gpu_mesh(pass, value.cube, model_matrix, {color = {228, 214, 164, 255}})
	rl.draw_gpu_mesh(
		pass,
		value.cube_edges,
		model_matrix,
		{color = {20, 32, 38, 255}, style = .Opaque_Outline},
	)
}

surfboard_fixture_boundary_reset :: proc(value: ^Client_State) {
	renderer := &value.terrain.ocean
	if !renderer.nearshore.fixture_active do return
	debug_ocean_fixture_cancel_pending_tick(renderer)
	renderer.nearshore.pending_control = {}
	renderer.surf_events.control = {}
	value.surfboard.control = {}
	events := &renderer.surf_events
	retained := 0
	for event in events.queue[:events.count] {
		if event.kind == .Control do continue
		events.queue[retained] = event
		retained += 1
	}
	for index in retained ..< events.count do events.queue[index] = {}
	events.count = retained
}

surfboard_deinit :: proc(value: ^Client_State) {
	assert(value != nil, "surfboard_deinit: nil state")
	if value.surfboard.fixture_physics != nil {
		surfboard_fixture_boundary_reset(value)
	}
	physics := value.surfboard.fixture_physics
	if physics == nil do physics = &value.cosmetics
	if b3.Body_IsValid(value.surfboard.body) {
		cosmetics_unregister_surfable(physics, value.surfboard.body)
		b3.DestroyBody(value.surfboard.body)
	}
	if b3.Body_IsValid(value.surfboard.fixture_body) do b3.DestroyBody(value.surfboard.fixture_body)
	if value.surfboard.fixture_mesh != nil do b3.DestroyMesh(value.surfboard.fixture_mesh)
	if value.surfboard.fixture_physics != nil {
		cosmetics_deinit(value.surfboard.fixture_physics)
		free(value.surfboard.fixture_physics)
	}
	value.surfboard = {}
}

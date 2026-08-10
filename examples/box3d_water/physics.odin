// examples/box3d_water - Box3D world construction and the fixed simulation
// step. The coupling to the water lives in physics_apply_water: Box3D never
// learns what water is, it only receives a force per floating body per step.
package main

import "core:math"
import "core:math/linalg"
import rl "ingot:gfx"
import b3 "vendor:box3d"

physics_create :: proc(value: ^State) -> bool {
	assert(value != nil, "physics_create: nil state")
	assert(FLOATER_COUNT <= FLOATER_MAX, "physics_create: floater capacity too small")
	world_def := b3.DefaultWorldDef()
	world_def.gravity = {0, 0, -WATER_GRAVITY}
	value.world = b3.CreateWorld(world_def)
	if !b3.World_IsValid(value.world) do return false
	if !floor_create(value) {
		physics_destroy(value)
		return false
	}
	for index in 0 ..< FLOATER_COUNT {
		if !floater_create(value, index) {
			physics_destroy(value)
			return false
		}
	}
	value.ready = true
	floater_transforms_sync(value)
	assert(value.floater_count == FLOATER_COUNT, "physics_create: incomplete pool")
	return true
}

// The floor is far below the surface. It exists so a body that is somehow
// pushed out of the buoyant band still has something to rest on instead of
// falling forever, which would hide the failure rather than show it.
floor_create :: proc(value: ^State) -> bool {
	assert(value != nil, "floor_create: nil state")
	assert(b3.World_IsValid(value.world), "floor_create: invalid world")
	body_def := b3.DefaultBodyDef()
	body_def.type = .staticBody
	body_def.position = {0, 0, FLOOR_Z - 1}
	value.floor = b3.CreateBody(value.world, body_def)
	if !b3.Body_IsValid(value.floor) do return false
	shape_def := b3.DefaultShapeDef()
	hull := b3.MakeBoxHull(POOL_EXTENT + 4, POOL_EXTENT + 4, 1)
	shape := b3.CreateHullShape(value.floor, shape_def, &hull.base)
	return b3.Shape_IsValid(shape)
}

// Floaters are placed on a deterministic ring rather than at random positions:
// the example's value is showing the same settling behaviour every run, and a
// seeded scatter would only add a knob that hides regressions.
floater_create :: proc(value: ^State, index: int) -> bool {
	assert(value != nil, "floater_create: nil state")
	assert(index >= 0 && index < FLOATER_COUNT, "floater_create: index out of range")
	angle := f32(index) * math.TAU / f32(FLOATER_COUNT)
	body_def := b3.DefaultBodyDef()
	body_def.type = .dynamicBody
	body_def.position = {6 * math.cos(angle), 6 * math.sin(angle), 4 + f32(index) * 0.6}
	body_def.angularDamping = 0.4
	body_def.enableSleep = false
	body := b3.CreateBody(value.world, body_def)
	if !b3.Body_IsValid(body) do return false
	shape_def := b3.DefaultShapeDef()
	shape_def.density = FLOATER_DENSITY
	shape_def.baseMaterial.friction = 0.3
	hull := b3.MakeCubeHull(FLOATER_HALF_EXTENT)
	shape := b3.CreateHullShape(body, shape_def, &hull.base)
	if !b3.Shape_IsValid(shape) {
		b3.DestroyBody(body)
		return false
	}
	value.floaters[index] = {
		body = body,
		mass = b3.Body_GetMass(body),
	}
	value.floater_count += 1
	return true
}

// physics_step is the one place the wave and the solver advance together. The
// force is applied before the step so Box3D integrates it, and the phase moves
// by exactly one fixed increment so the water can never drift relative to the
// bodies no matter how the frame rate varies.
physics_step :: proc(value: ^State) {
	assert(value != nil, "physics_step: nil state")
	assert(value.floater_count <= FLOATER_MAX, "physics_step: floater count overflow")
	physics_apply_water(value)
	b3.World_Step(value.world, FIXED_DT, PHYSICS_SUBSTEPS)
	value.phase += WATER_PHASE_RATE * FIXED_DT
	// Phase is an angle, so folding it back keeps it small forever. Without
	// this a long-running session loses float precision in the sine argument
	// and the wave visibly stutters.
	if value.phase >= WATER_PHASE_PERIOD do value.phase -= WATER_PHASE_PERIOD
	value.fixed_steps += 1
}

physics_apply_water :: proc(value: ^State) {
	assert(value != nil, "physics_apply_water: nil state")
	assert(value.floater_count <= FLOATER_MAX, "physics_apply_water: count overflow")
	for &floater in value.floaters[:value.floater_count] {
		if !b3.Body_IsValid(floater.body) do continue
		center := b3.Body_GetWorldCenter(floater.body)
		velocity := b3.Body_GetLinearVelocity(floater.body)
		// Solver state is untrusted input to the water model, not a value
		// this code produced. A body that has already diverged is skipped
		// rather than asserted on: pushing a force onto a non-finite
		// position is meaningless, and aborting the whole app over one bad
		// body would turn a recoverable visual glitch into a crash.
		position := [3]f32{f32(center.x), f32(center.y), f32(center.z)}
		if !water_vector_finite(position) do continue
		if !water_vector_finite(velocity) do continue
		surface := water_height(position.x, position.y, value.phase)
		surface_velocity := water_surface_velocity(position.x, position.y, value.phase)
		floater.submerged = water_submerged_fraction(position.z, FLOATER_HALF_EXTENT, surface)
		force := water_force(
			position.z,
			FLOATER_HALF_EXTENT,
			floater.mass,
			surface,
			surface_velocity,
			velocity,
		)
		b3.Body_ApplyForceToCenter(floater.body, force, true)
	}
}

physics_update :: proc(value: ^State, frame_dt: f32) {
	assert(value != nil, "physics_update: nil state")
	assert(value.floater_count <= FLOATER_MAX, "physics_update: floater count overflow")
	value.fixed_steps = 0
	if !value.ready do return
	if value.paused && !value.step_once do return
	if value.step_once {
		physics_step(value)
		value.step_once = false
		floater_transforms_sync(value)
		return
	}
	value.accumulator += clamp(frame_dt, 0, MAX_FRAME_DT)
	for _ in 0 ..< MAX_STEPS_PER_FRAME {
		if value.accumulator < FIXED_DT do break
		physics_step(value)
		value.accumulator -= FIXED_DT
	}
	// Dropping the backlog rather than working through it is deliberate: a
	// stalled frame must not turn into an unbounded burst of steps, and the
	// counter makes the loss visible in the HUD instead of silent.
	if value.accumulator >= FIXED_DT {
		dropped := u64(value.accumulator / FIXED_DT)
		value.accumulator -= f32(dropped) * FIXED_DT
		value.dropped_steps += dropped
	}
	floater_transforms_sync(value)
}

floater_transforms_sync :: proc(value: ^State) {
	assert(value != nil, "floater_transforms_sync: nil state")
	assert(value.floater_count <= FLOATER_MAX, "floater_transforms_sync: overflow")
	scale := [3]f32{FLOATER_HALF_EXTENT * 2, FLOATER_HALF_EXTENT * 2, FLOATER_HALF_EXTENT * 2}
	for &floater in value.floaters[:value.floater_count] {
		if !b3.Body_IsValid(floater.body) do continue
		transform := b3.Body_GetTransform(floater.body)
		position := [3]f32{f32(transform.p.x), f32(transform.p.y), f32(transform.p.z)}
		floater.transform = linalg.matrix4_from_trs_f32(position, transform.q, scale)
	}
}

simulation_input :: proc(value: ^State) {
	assert(value != nil, "simulation_input: nil state")
	assert(value.floater_count <= FLOATER_MAX, "simulation_input: count overflow")
	if rl.IsKeyPressed(.SPACE) do value.paused = !value.paused
	if rl.IsKeyPressed(.N) && value.paused do value.step_once = true
	if rl.IsKeyPressed(.R) {
		paused := value.paused
		physics_destroy(value)
		if !physics_create(value) {
			value.paused = paused
			return
		}
		value.paused = paused
	}
}

physics_destroy :: proc(value: ^State) {
	assert(value != nil, "physics_destroy: nil state")
	assert(value.floater_count <= FLOATER_MAX, "physics_destroy: count overflow")
	if b3.World_IsValid(value.world) do b3.DestroyWorld(value.world)
	value.world = {}
	value.floor = {}
	value.floaters = {}
	value.floater_count = 0
	value.phase = 0
	value.accumulator = 0
	value.fixed_steps = 0
	value.step_once = false
	value.ready = false
	assert(value.floater_count == 0, "physics_destroy: state not cleared")
}

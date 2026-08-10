package main

import "base:intrinsics"
import rl "ingot:gfx"
import b3 "vendor:box3d"

BODY_COUNT :: #config(INGOT_BOX3D_BENCHMARK_BODY_COUNT, 4000)
PILE_COLUMNS :: #config(INGOT_BOX3D_BENCHMARK_PILE_COLUMNS, 20)
PILE_ROWS :: #config(INGOT_BOX3D_BENCHMARK_PILE_ROWS, 10)
WARMUP_STEPS :: #config(INGOT_BOX3D_BENCHMARK_WARMUP_STEPS, 60)
MEASURED_BATCH_COUNT :: #config(INGOT_BOX3D_BENCHMARK_MEASURED_BATCH_COUNT, 5)
STEPS_PER_BATCH :: #config(INGOT_BOX3D_BENCHMARK_STEPS_PER_BATCH, 30)
PHYSICS_SUBSTEPS :: #config(INGOT_BOX3D_BENCHMARK_PHYSICS_SUBSTEPS, 4)
BODY_COUNT_MAX :: 10_000
PILE_COLUMNS_MAX :: 64
PILE_ROWS_MAX :: 64
WARMUP_STEPS_MAX :: 600
MEASURED_BATCH_COUNT_MAX :: 64
STEPS_PER_BATCH_MAX :: 600
PHYSICS_SUBSTEPS_MAX :: 16
BOX3D_WORKERS_ENABLED :: ODIN_OS == .JS && #config(INGOT_BOX3D_WORKERS, false)
BOX3D_TASK_MAX :: b3.MAX_TASKS

Box3D_Task_Status :: enum u32 {
	Free,
	Reserved,
	Pending,
	Complete,
	Failed,
}

Box3D_Task_Slot :: struct {
	status:       Box3D_Task_Status,
	task:         rawptr,
	task_context: rawptr,
	generation:   u32,
}

Benchmark_Oracle :: struct {
	checksum:            u64,
	body_count:          i32,
	contact_count:       i32,
	awake_contact_count: i32,
	island_count:        i32,
	task_count:          i32,
	profile_step_ms:     f32,
	profile_collide_ms:  f32,
	profile_solve_ms:    f32,
}

State :: struct {
	world:      b3.WorldId,
	bodies:     [BODY_COUNT_MAX]b3.BodyId,
	body_count: int,
	ready:      bool,
	oracle:     Benchmark_Oracle,
}

when BOX3D_WORKERS_ENABLED {
	foreign import box3d_workers "ingot_box3d_workers"
	@(default_calling_convention = "c")
	foreign box3d_workers {
		@(link_name = "schedule")
		box3d_worker_schedule :: proc(slot, generation: u32) -> bool ---
		@(link_name = "request_batch")
		box3d_worker_request_batch :: proc(step_count: u32) -> bool ---
		@(link_name = "worker_count")
		box3d_worker_count :: proc() -> u32 ---
	}
}

box3d_task_slots: [BOX3D_TASK_MAX]Box3D_Task_Slot
box3d_batch_pending: u32
state: State

main :: proc() {
	assert(BODY_COUNT > 0 && BODY_COUNT <= BODY_COUNT_MAX)
	assert(PILE_COLUMNS > 0 && PILE_COLUMNS <= PILE_COLUMNS_MAX)
	assert(PILE_ROWS > 0 && PILE_ROWS <= PILE_ROWS_MAX)
	assert(WARMUP_STEPS >= 0 && WARMUP_STEPS <= WARMUP_STEPS_MAX)
	assert(MEASURED_BATCH_COUNT > 0 && MEASURED_BATCH_COUNT <= MEASURED_BATCH_COUNT_MAX)
	assert(STEPS_PER_BATCH > 0 && STEPS_PER_BATCH <= STEPS_PER_BATCH_MAX)
	assert(PHYSICS_SUBSTEPS > 0 && PHYSICS_SUBSTEPS <= PHYSICS_SUBSTEPS_MAX)

	rl.InitWindow(1024, 576, "Box3D browser worker benchmark")
	rl.SetTargetFPS(60)
	benchmark_world_init()
	rl.run(frame)
	when ODIN_OS != .JS {
		b3.DestroyWorld(state.world)
		rl.CloseWindow()
	}
}

benchmark_world_init :: proc() {
	world_def := b3.DefaultWorldDef()
	world_def.gravity = {0, 0, -10}
	world_def.enableSleep = false
	when BOX3D_WORKERS_ENABLED {
		world_def.workerCount = box3d_worker_count()
		world_def.enqueueTask = box3d_worker_enqueue
		world_def.finishTask = box3d_worker_finish
	}
	state.world = b3.CreateWorld(world_def)
	assert(b3.World_IsValid(state.world))

	ground_def := b3.DefaultBodyDef()
	ground_def.position = {0, 0, -1}
	ground := b3.CreateBody(state.world, ground_def)
	assert(b3.Body_IsValid(ground))
	ground_hull := b3.MakeBoxHull(80, 80, 1)
	ground_shape := b3.CreateHullShape(ground, b3.DefaultShapeDef(), &ground_hull.base)
	assert(b3.Shape_IsValid(ground_shape))

	box_hull := b3.MakeCubeHull(0.5)
	shape_def := b3.DefaultShapeDef()
	shape_def.density = 1
	shape_def.baseMaterial.friction = 0.6
	bodies_per_pile := PILE_COLUMNS * PILE_ROWS
	pile_grid_width := 5
	for index in 0 ..< BODY_COUNT {
		pile := index / bodies_per_pile
		local := index % bodies_per_pile
		column := local % PILE_COLUMNS
		row := local / PILE_COLUMNS
		pile_x := pile % pile_grid_width
		pile_y := pile / pile_grid_width
		body_def := b3.DefaultBodyDef()
		body_def.type = .dynamicBody
		body_def.enableSleep = false
		body_def.position = {
			f32(pile_x * (PILE_COLUMNS + 3) + column) - 45.0 + f32(row % 2) * 0.025,
			f32(pile_y * 4) - 20.0 + f32(column % 3) * 0.01,
			0.51 + f32(row) * 1.005,
		}
		body := b3.CreateBody(state.world, body_def)
		assert(b3.Body_IsValid(body))
		shape := b3.CreateHullShape(body, shape_def, &box_hull.base)
		assert(b3.Shape_IsValid(shape))
		state.bodies[index] = body
		state.body_count += 1
	}
	state.ready = state.body_count == BODY_COUNT
}

checksum_mix :: proc "contextless" (checksum: u64, value: f32) -> u64 {
	bits := transmute(u32)value
	return (checksum ~ u64(bits)) * 1099511628211
}

benchmark_oracle_record :: proc "contextless" () {
	checksum: u64 = 14695981039346656037
	sample_count := min(BODY_COUNT, 128)
	for sample in 0 ..< sample_count {
		index := sample * BODY_COUNT / sample_count
		transform := b3.Body_GetTransform(state.bodies[index])
		if !b3.IsValidWorldTransform(transform) do continue
		checksum = checksum_mix(checksum, f32(transform.p.x))
		checksum = checksum_mix(checksum, f32(transform.p.y))
		checksum = checksum_mix(checksum, f32(transform.p.z))
		checksum = checksum_mix(checksum, transform.q.x)
		checksum = checksum_mix(checksum, transform.q.y)
		checksum = checksum_mix(checksum, transform.q.z)
		checksum = checksum_mix(checksum, transform.q.w)
	}
	counters := b3.World_GetCounters(state.world)
	profile := b3.World_GetProfile(state.world)
	state.oracle = {
		checksum            = checksum,
		body_count          = i32(counters.bodyCount),
		contact_count       = i32(counters.contactCount),
		awake_contact_count = i32(counters.awakeContactCount),
		island_count        = i32(counters.islandCount),
		task_count          = i32(counters.taskCount),
		profile_step_ms     = profile.step,
		profile_collide_ms  = profile.collide,
		profile_solve_ms    = profile.solve,
	}
}

frame :: proc() {
	rl.BeginDrawing()
	rl.ClearBackground(rl.Color{24, 26, 32, 255})
	rl.DrawText("Box3D browser worker benchmark", 24, 24, 24, rl.RAYWHITE)
	if state.ready {
		rl.DrawText("deterministic convex piles ready", 24, 58, 20, rl.LIGHTGRAY)
	}
	rl.EndDrawing()
}

when BOX3D_WORKERS_ENABLED {
	box3d_worker_enqueue :: proc "c" (
		task, task_context, user_context: rawptr,
		task_name: cstring,
	) -> rawptr {
		_ = user_context
		_ = task_name
		for index in 0 ..< BOX3D_TASK_MAX {
			slot := &box3d_task_slots[index]
			_, claimed := intrinsics.atomic_compare_exchange_strong_explicit(
				&slot.status,
				.Free,
				.Reserved,
				.Acq_Rel,
				.Acquire,
			)
			if !claimed do continue
			slot.task = task
			slot.task_context = task_context
			slot.generation += 1
			intrinsics.atomic_store_explicit(&slot.status, .Pending, .Release)
			if box3d_worker_schedule(u32(index), slot.generation) do return slot
			callback := transmute(b3.TaskCallback)task
			callback(task_context)
			intrinsics.atomic_store_explicit(&slot.status, .Free, .Release)
			return nil
		}
		callback := transmute(b3.TaskCallback)task
		callback(task_context)
		return nil
	}

	box3d_worker_finish :: proc "c" (user_task, user_context: rawptr) {
		_ = user_context
		if user_task == nil do return
		slot := (^Box3D_Task_Slot)(user_task)
		for attempt in 0 ..< BOX3D_TASK_MAX {
			status := intrinsics.atomic_load_explicit(&slot.status, .Acquire)
			if status == .Complete || status == .Failed do break
			_ = intrinsics.wasm_memory_atomic_wait32(
				(^u32)(&slot.status),
				u32(Box3D_Task_Status.Pending),
				1_000_000_000,
			)
			if attempt + 1 >= BOX3D_TASK_MAX do return
		}
		if slot.status != .Complete do return
		intrinsics.atomic_store_explicit(&slot.status, .Free, .Release)
	}

	@(export, link_name = "ingot_box3d_worker_dispatch")
	box3d_worker_dispatch :: proc "contextless" (index, generation: u32) -> bool {
		if index >= BOX3D_TASK_MAX do return false
		slot := &box3d_task_slots[index]
		if slot.generation != generation do return false
		if intrinsics.atomic_load_explicit(&slot.status, .Acquire) != .Pending do return false
		callback := transmute(b3.TaskCallback)slot.task
		callback(slot.task_context)
		intrinsics.atomic_store_explicit(&slot.status, .Complete, .Release)
		_ = intrinsics.wasm_memory_atomic_notify32((^u32)(&slot.status), 1)
		return true
	}

	@(export, link_name = "ingot_box3d_benchmark_batch")
	box3d_benchmark_batch :: proc "contextless" (step_count: u32) -> bool {
		if !b3.World_IsValid(state.world) do return false
		if step_count == 0 || step_count > STEPS_PER_BATCH_MAX do return false
		for _ in 0 ..< step_count {
			b3.World_Step(state.world, 1.0 / 60.0, PHYSICS_SUBSTEPS)
		}
		benchmark_oracle_record()
		intrinsics.atomic_store_explicit(&box3d_batch_pending, 0, .Release)
		return true
	}
}

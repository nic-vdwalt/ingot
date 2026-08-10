package main

import "base:intrinsics"
import "core:fmt"
import "core:time"
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

Benchmark_Phase :: enum u32 {
	Warmup,
	Measured,
	Complete,
	Failed,
}

Benchmark_Oracle :: struct {
	checksum:            u64,
	body_count:          i32,
	contact_count:       i32,
	awake_contact_count: i32,
	island_count:        i32,
	task_count:          i32,
}

State :: struct {
	world:      b3.WorldId,
	bodies:     [BODY_COUNT_MAX]b3.BodyId,
	body_count: int,
	ready:      bool,
	oracle:          Benchmark_Oracle,
	phase:           Benchmark_Phase,
	warmup_complete: int,
	batches_complete: int,
	measured_steps:  int,
	total_ms:        f64,
	reported:        bool,
	profile_step_sum:     f64,
	profile_pairs_sum:    f64,
	profile_collide_sum:  f64,
	profile_solve_sum:    f64,
	profile_sample_count: int,
}

when BOX3D_WORKERS_ENABLED {
	foreign import box3d_workers "ingot_box3d_workers"
	@(default_calling_convention = "c")
	foreign box3d_workers {
		@(link_name = "schedule")
		box3d_worker_schedule :: proc(slot, generation: u32) -> bool ---
		@(link_name = "request_batch")
		box3d_worker_request_batch :: proc(step_count: u32) -> bool ---
		@(link_name = "batch_ready")
		box3d_worker_batch_ready :: proc() -> bool ---
		@(link_name = "batch_elapsed_micros")
		box3d_worker_batch_elapsed_micros :: proc() -> u32 ---
		@(link_name = "batch_step_count")
		box3d_worker_batch_step_count :: proc() -> u32 ---
		@(link_name = "task_count")
		box3d_worker_task_count :: proc() -> u32 ---
		@(link_name = "queue_high_water")
		box3d_worker_queue_high_water :: proc() -> u32 ---
		@(link_name = "failure_count")
		box3d_worker_failure_count :: proc() -> u32 ---
		@(link_name = "worker_count")
		box3d_worker_count :: proc() -> u32 ---
	}
}

box3d_task_slots: [BOX3D_TASK_MAX]Box3D_Task_Slot
box3d_batch_pending: u32
state: State

when ODIN_OS == .JS {
	@(export, link_name = "b3PlatformTicks")
	box3d_platform_ticks :: proc "c" () -> u64 {
		nanos := time.tick_now()._nsec
		if nanos <= 0 do return 0
		return u64(nanos) / 1000
	}
}

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

benchmark_step_once :: proc "contextless" () {
	b3.World_Step(state.world, 1.0 / 60.0, PHYSICS_SUBSTEPS)
	if state.phase != .Measured do return
	profile := b3.World_GetProfile(state.world)
	state.profile_step_sum += f64(profile.step)
	state.profile_pairs_sum += f64(profile.pairs)
	state.profile_collide_sum += f64(profile.collide)
	state.profile_solve_sum += f64(profile.solve)
	state.profile_sample_count += 1
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
	state.oracle = {
		checksum            = checksum,
		body_count          = i32(counters.bodyCount),
		contact_count       = i32(counters.contactCount),
		awake_contact_count = i32(counters.awakeContactCount),
		island_count        = i32(counters.islandCount),
		task_count          = i32(counters.taskCount),
	}
}

benchmark_batch_complete :: proc(step_count: int, elapsed_ms: f64) {
	if state.phase == .Warmup {
		state.warmup_complete += step_count
		if state.warmup_complete >= WARMUP_STEPS do state.phase = .Measured
	} else if state.phase == .Measured {
		state.batches_complete += 1
		state.measured_steps += step_count
		state.total_ms += elapsed_ms
		if state.batches_complete >= MEASURED_BATCH_COUNT do state.phase = .Complete
	}
}

benchmark_batch_request :: proc(step_count: int) {
	assert(step_count > 0 && step_count <= STEPS_PER_BATCH_MAX)
	when BOX3D_WORKERS_ENABLED {
		intrinsics.atomic_store_explicit(&box3d_batch_pending, 1, .Release)
		if box3d_worker_request_batch(u32(step_count)) do return
		started := rl.GetTime()
		ok := box3d_benchmark_batch(u32(step_count))
		intrinsics.atomic_store_explicit(&box3d_batch_pending, 0, .Release)
		if !ok {
			state.phase = .Failed
			return
		}
		benchmark_batch_complete(step_count, (rl.GetTime() - started) * 1000)
	} else {
		started := rl.GetTime()
		for _ in 0 ..< step_count {
			benchmark_step_once()
		}
		benchmark_oracle_record()
		benchmark_batch_complete(step_count, (rl.GetTime() - started) * 1000)
	}
}

benchmark_report :: proc() {
	if state.reported || state.phase != .Complete do return
	worker_count: u32 = 1
	task_count: u32 = 0
	queue_high_water: u32 = 0
	failures: u32 = 0
	when BOX3D_WORKERS_ENABLED {
		worker_count = box3d_worker_count()
		task_count = box3d_worker_task_count()
		queue_high_water = box3d_worker_queue_high_water()
		failures = box3d_worker_failure_count()
	}
	ms_per_step := state.total_ms / f64(max(state.measured_steps, 1))
	steps_per_second := 1000 / ms_per_step
	profile_samples := f64(max(state.profile_sample_count, 1))
	profile_step_ms := state.profile_step_sum / profile_samples
	profile_pairs_ms := state.profile_pairs_sum / profile_samples
	profile_collide_ms := state.profile_collide_sum / profile_samples
	profile_solve_ms := state.profile_solve_sum / profile_samples
	fmt.printfln(
		"INGOT_BOX3D_BENCHMARK %c\"body_count\":%d,\"worker_count\":%d,\"steps\":%d,\"total_ms\":%.3f,\"ms_per_step\":%.6f,\"steps_per_second\":%.3f,\"profile_step_ms\":%.4f,\"profile_pairs_ms\":%.4f,\"profile_collide_ms\":%.4f,\"profile_solve_ms\":%.4f,\"profile_samples\":%d,\"task_count\":%d,\"queue_high_water\":%d,\"failure_count\":%d,\"checksum\":\"%016x\",\"contacts\":%d,\"awake_contacts\":%d,\"islands\":%d%c",
		'{',
		BODY_COUNT,
		worker_count,
		state.measured_steps,
		state.total_ms,
		ms_per_step,
		steps_per_second,
		profile_step_ms,
		profile_pairs_ms,
		profile_collide_ms,
		profile_solve_ms,
		state.profile_sample_count,
		task_count,
		queue_high_water,
		failures,
		state.oracle.checksum,
		state.oracle.contact_count,
		state.oracle.awake_contact_count,
		state.oracle.island_count,
		'}',
	)
	state.reported = true
}

benchmark_update :: proc() {
	if !state.ready || state.phase == .Failed do return
	if state.phase == .Complete {
		benchmark_report()
		return
	}
	when BOX3D_WORKERS_ENABLED {
		if box3d_worker_failure_count() > 0 {
			state.phase = .Failed
			return
		}
		if box3d_worker_batch_ready() {
			intrinsics.atomic_store_explicit(&box3d_batch_pending, 0, .Release)
			benchmark_batch_complete(
				int(box3d_worker_batch_step_count()),
				f64(box3d_worker_batch_elapsed_micros()) / 1000,
			)
			return
		}
		if intrinsics.atomic_load_explicit(&box3d_batch_pending, .Acquire) != 0 do return
	}
	if state.phase == .Warmup {
		remaining := WARMUP_STEPS - state.warmup_complete
		if remaining <= 0 {
			state.phase = .Measured
		} else {
			benchmark_batch_request(min(remaining, STEPS_PER_BATCH))
		}
	} else if state.phase == .Measured {
		benchmark_batch_request(STEPS_PER_BATCH)
	}
	benchmark_report()
}

frame :: proc() {
	benchmark_update()
	rl.BeginDrawing()
	rl.ClearBackground(rl.Color{24, 26, 32, 255})
	rl.DrawText("Box3D browser worker benchmark", 24, 24, 24, rl.RAYWHITE)
	if state.ready {
		rl.DrawText("deterministic convex piles ready", 24, 58, 20, rl.LIGHTGRAY)
	}
	status := fmt.ctprintf(
		"phase %v  warmup %d/%d  batches %d/%d",
		state.phase,
		state.warmup_complete,
		WARMUP_STEPS,
		state.batches_complete,
		MEASURED_BATCH_COUNT,
	)
	rl.DrawText(status, 24, 90, 20, rl.LIGHTGRAY)
	if state.phase == .Complete {
		result := fmt.ctprintf(
			"%.3f ms total  %.6f ms/step  checksum %016x",
			state.total_ms,
			state.total_ms / f64(max(state.measured_steps, 1)),
			state.oracle.checksum,
		)
		rl.DrawText(result, 24, 122, 20, rl.GREEN)
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
			benchmark_step_once()
		}
		benchmark_oracle_record()
		return true
	}
}

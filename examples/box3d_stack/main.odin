package main

import "base:intrinsics"
import "core:math/linalg"
import rl "ingot:gfx"
import b3 "vendor:box3d"

NUM_BOXES :: 25

BOX3D_WORKERS_ENABLED :: ODIN_OS == .JS && #config(INGOT_BOX3D_WORKERS, false)
BOX3D_WORKER_COUNT :: 4
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

State :: struct {
	world:      b3.WorldId,
	boxes:      [NUM_BOXES]b3.BodyId,
	transforms: [NUM_BOXES]b3.WorldTransform,
	camera:     rl.Camera3D,
}

when BOX3D_WORKERS_ENABLED {
	foreign import box3d_workers "ingot_box3d_workers"
	@(default_calling_convention = "c")
	foreign box3d_workers {
		@(link_name = "schedule")
		box3d_worker_schedule :: proc(slot, generation: u32) -> bool ---
		@(link_name = "request_step")
		box3d_worker_request_step :: proc() -> bool ---
	}
}

box3d_task_slots: [BOX3D_TASK_MAX]Box3D_Task_Slot
box3d_step_pending: u32
state: State

main :: proc() {
	rl.InitWindow(1024, 768, "Box3D + Ingot sample")
	state.camera = {
		position   = {25, -25, 15},
		up         = {0, 0, 1},
		fovy       = 45,
		projection = .PERSPECTIVE,
	}
	rl.SetTargetFPS(60)

	world_def := b3.DefaultWorldDef()
	world_def.gravity = {0, 0, -10}
	when BOX3D_WORKERS_ENABLED {
		world_def.workerCount = BOX3D_WORKER_COUNT
		world_def.enqueueTask = box3d_worker_enqueue
		world_def.finishTask = box3d_worker_finish
	}
	state.world = b3.CreateWorld(world_def)

	ground_body_def := b3.DefaultBodyDef()
	ground_body_def.position = {0, 0, -10}
	ground_id := b3.CreateBody(state.world, ground_body_def)

	ground_box := b3.MakeBoxHull(50, 50, 10)
	ground_shape_def := b3.DefaultShapeDef()
	_ = b3.CreateHullShape(ground_id, ground_shape_def, &ground_box.base)

	for i in 0 ..< len(state.boxes) {
		body_def := b3.DefaultBodyDef()
		body_def.type = .dynamicBody
		offset_x := f32(0.05 if i % 2 == 0 else -0.05)
		body_def.position = {offset_x, 0, 2 + f32(i) * 2.5}
		state.boxes[i] = b3.CreateBody(state.world, body_def)

		dynamic_box := b3.MakeCubeHull(1)
		shape_def := b3.DefaultShapeDef()
		shape_def.density = 1
		shape_def.baseMaterial.friction = 0.3
		_ = b3.CreateHullShape(state.boxes[i], shape_def, &dynamic_box.base)
	}
	box_transforms_sync()

	rl.run(frame)
	when ODIN_OS != .JS {
		b3.DestroyWorld(state.world)
		rl.CloseWindow()
	}
}

frame :: proc() {
	when BOX3D_WORKERS_ENABLED {
		if intrinsics.atomic_load_explicit(&box3d_step_pending, .Acquire) == 0 {
			box_transforms_sync()
			intrinsics.atomic_store_explicit(&box3d_step_pending, 1, .Release)
			if !box3d_worker_request_step() {
				intrinsics.atomic_store_explicit(&box3d_step_pending, 0, .Release)
				b3.World_Step(state.world, 1.0 / 60.0, 4)
			}
		}
	} else {
		b3.World_Step(state.world, 1.0 / 60.0, 4)
		box_transforms_sync()
	}

	rl.BeginDrawing()
	rl.ClearBackground(rl.RAYWHITE)
	rl.BeginMode3D(state.camera)

	rl.DrawCube({0, 0, -2}, 100, 100, 4, rl.LIGHTGRAY)
	rl.DrawCubeWires({0, 0, -2}, 100, 100, 4, rl.GRAY)

	for transform in state.transforms {
		model := linalg.matrix4_from_trs_f32(transform.p, transform.q, [3]f32{2, 2, 2})
		rl.DrawCubeTransform(model, rl.BLUE)
		rl.DrawCubeWiresTransform(model, rl.DARKBLUE)
	}

	rl.DrawGrid(20, 5)
	rl.EndMode3D()
	rl.DrawFPS(10, 10)
	rl.DrawText("Box3D + Ingot sample", 10, 35, 20, rl.DARKGRAY)
	rl.EndDrawing()
}

box_transforms_sync :: proc() {
	for box, index in state.boxes {
		state.transforms[index] = b3.Body_GetTransform(box)
	}
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
			if box3d_worker_schedule(u32(index), slot.generation) {
				return slot
			}
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

	@(export, link_name = "ingot_box3d_worker_step")
	box3d_worker_step :: proc "contextless" () -> bool {
		if !b3.World_IsValid(state.world) do return false
		b3.World_Step(state.world, 1.0 / 60.0, 4)
		intrinsics.atomic_store_explicit(&box3d_step_pending, 0, .Release)
		return true
	}
}

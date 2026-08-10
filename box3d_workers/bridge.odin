package box3d_workers

import "base:intrinsics"
import "base:runtime"
import b3 "vendor:box3d"

ENABLED :: ODIN_OS == .JS && #config(INGOT_BOX3D_WORKERS, false)
TASK_MAX :: b3.MAX_TASKS
WAIT_TIMEOUT_NS :: i64(1_000_000_000)

Task_Status :: enum u32 {
	Free,
	Reserved,
	Pending,
	Complete,
	Failed,
}

Task_Slot :: struct {
	status:       Task_Status,
	task:         rawptr,
	task_context: rawptr,
	generation:   u32,
}

slots: [TASK_MAX]Task_Slot

when ENABLED {
	foreign import workers "ingot_box3d_workers"
	@(default_calling_convention = "c")
	foreign workers {
		@(link_name = "schedule")
		schedule :: proc(slot, generation: u32) -> bool ---
		@(link_name = "request_step")
		request_step_import :: proc() -> bool ---
		@(link_name = "request_batch")
		request_batch_import :: proc(step_count: u32) -> bool ---
		@(link_name = "request_command")
		request_command_import :: proc(command, value: u32) -> bool ---
		@(link_name = "step_ready")
		step_ready_import :: proc() -> bool ---
		@(link_name = "batch_ready")
		batch_ready_import :: proc() -> bool ---
		@(link_name = "command_ready")
		command_ready_import :: proc() -> bool ---
		@(link_name = "elapsed_micros")
		elapsed_micros_import :: proc() -> u32 ---
		@(link_name = "completed_value")
		completed_value_import :: proc() -> u32 ---
		@(link_name = "task_count")
		task_count_import :: proc() -> u32 ---
		@(link_name = "queue_high_water")
		queue_high_water_import :: proc() -> u32 ---
		@(link_name = "failure_count")
		failure_count_import :: proc() -> u32 ---
		@(link_name = "completion_generation")
		completion_generation_import :: proc() -> u32 ---
		@(link_name = "worker_count")
		worker_count_import :: proc() -> u32 ---
	}
}

configure_world :: proc(world_def: ^b3.WorldDef) {
	assert(world_def != nil)
	when ENABLED {
		count := worker_count_import()
		assert(count >= 2)
		assert(count <= 4)
		world_def.workerCount = count
		world_def.enqueueTask = enqueue
		world_def.finishTask = finish
	}
}

worker_count :: proc() -> u32 {
	when ENABLED do return worker_count_import()
	return 1
}

request_step :: proc() -> bool {
	when ENABLED do return request_step_import()
	return false
}

request_batch :: proc(step_count: u32) -> bool {
	assert(step_count > 0)
	when ENABLED do return request_batch_import(step_count)
	return false
}

request_command :: proc(command, value: u32) -> bool {
	assert(command > 0)
	when ENABLED do return request_command_import(command, value)
	return false
}

step_ready :: proc() -> bool {
	when ENABLED do return step_ready_import()
	return false
}

batch_ready :: proc() -> bool {
	when ENABLED do return batch_ready_import()
	return false
}

command_ready :: proc() -> bool {
	when ENABLED do return command_ready_import()
	return false
}

elapsed_micros :: proc() -> u32 {
	when ENABLED do return elapsed_micros_import()
	return 0
}

completed_value :: proc() -> u32 {
	when ENABLED do return completed_value_import()
	return 0
}

task_count :: proc() -> u32 {
	when ENABLED do return task_count_import()
	return 0
}

queue_high_water :: proc() -> u32 {
	when ENABLED do return queue_high_water_import()
	return 0
}

failure_count :: proc() -> u32 {
	when ENABLED do return failure_count_import()
	return 0
}

completion_generation :: proc() -> u32 {
	when ENABLED do return completion_generation_import()
	return 0
}

when ENABLED {
	enqueue :: proc "c" (
		task, task_context, user_context: rawptr,
		task_name: cstring,
	) -> rawptr {
		context = runtime.default_context()
		_ = user_context
		_ = task_name
		assert(task != nil)
		for index in 0 ..< TASK_MAX {
			slot := &slots[index]
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
			if schedule(u32(index), slot.generation) do return slot
			callback := transmute(b3.TaskCallback)task
			callback(task_context)
			intrinsics.atomic_store_explicit(&slot.status, .Free, .Release)
			return nil
		}
		callback := transmute(b3.TaskCallback)task
		callback(task_context)
		return nil
	}

	finish :: proc "c" (user_task, user_context: rawptr) {
		_ = user_context
		if user_task == nil do return
		slot := (^Task_Slot)(user_task)
		for attempt in 0 ..< TASK_MAX {
			status := intrinsics.atomic_load_explicit(&slot.status, .Acquire)
			if status == .Complete || status == .Failed do break
			_ = intrinsics.wasm_memory_atomic_wait32(
				(^u32)(&slot.status),
				u32(Task_Status.Pending),
				WAIT_TIMEOUT_NS,
			)
			if attempt + 1 >= TASK_MAX do return
		}
		if slot.status != .Complete do return
		intrinsics.atomic_store_explicit(&slot.status, .Free, .Release)
	}

	@(export, link_name = "ingot_box3d_worker_dispatch")
	dispatch :: proc "contextless" (index, generation: u32) -> bool {
		if index >= TASK_MAX do return false
		slot := &slots[index]
		if slot.generation != generation do return false
		if intrinsics.atomic_load_explicit(&slot.status, .Acquire) != .Pending do return false
		callback := transmute(b3.TaskCallback)slot.task
		if callback == nil do return false
		callback(slot.task_context)
		intrinsics.atomic_store_explicit(&slot.status, .Complete, .Release)
		_ = intrinsics.wasm_memory_atomic_notify32((^u32)(&slot.status), 1)
		return true
	}
}

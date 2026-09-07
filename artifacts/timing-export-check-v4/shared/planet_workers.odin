package shared

import "core:sync"
import "core:thread"

// Planet_Workers is the one persistent worker team every planetary system
// shares. Workers block on their own semaphore between jobs (no idle
// polling, and no worker can consume another worker's wake-up), a job is one
// proc run once per worker with the same data pointer, and a barrier lets a
// job separate its phases so a later phase never reads what an earlier phase
// is still writing. The team is created with the world and joined at deinit;
// no simulation path creates threads after that.
//
// With zero workers (thread creation failed, or a bare Planetary_State in a
// test) planet_workers_run calls the job inline as worker 0 of 1 and the
// barrier is a no-op, so every job body is also its own serial reference.

PLANET_WORKERS_MAX :: PLANET_SIM_FACE_COUNT

Planet_Worker_Proc :: #type proc(data: rawptr, worker, workers: int, team: ^Planet_Workers)

Planet_Worker_Slot :: struct {
	team:     ^Planet_Workers,
	worker:   int,
	dispatch: sync.Sema,
}

Planet_Workers :: struct {
	threads:  [PLANET_WORKERS_MAX]^thread.Thread,
	slots:    [PLANET_WORKERS_MAX]Planet_Worker_Slot,
	count:    int,
	barrier:  sync.Barrier,
	complete: sync.Sema,
	shutdown: bool,
	job:      Planet_Worker_Proc,
	data:     rawptr,
}

planet_workers_init :: proc(team: ^Planet_Workers, count := PLANET_WORKERS_MAX) {
	assert(team != nil, "planet_workers_init: nil team")
	assert(count >= 0 && count <= PLANET_WORKERS_MAX, "planet_workers_init: count")
	team^ = {}
	for worker in 0 ..< count {
		team.slots[worker] = {team = team, worker = worker}
		team.threads[worker] = thread.create_and_start_with_poly_data(
			&team.slots[worker],
			_planet_worker_loop,
		)
		if team.threads[worker] == nil do break
		team.count += 1
	}
	if team.count > 0 do sync.barrier_init(&team.barrier, team.count)
}

planet_workers_deinit :: proc(team: ^Planet_Workers) {
	assert(team != nil, "planet_workers_deinit: nil team")
	if team.count > 0 {
		sync.atomic_store(&team.shutdown, true)
		for worker in 0 ..< team.count do sync.post(&team.slots[worker].dispatch, 1)
		for worker in 0 ..< team.count {
			thread.join(team.threads[worker])
			thread.destroy(team.threads[worker])
		}
	}
	team^ = {}
}

// planet_workers_count is the number of job invocations planet_workers_run
// makes: the team size, or one for a nil or empty (inline) team.
planet_workers_count :: proc(team: ^Planet_Workers) -> int {
	if team == nil do return 1
	return max(team.count, 1)
}

// planet_workers_run executes job once per worker and returns when every
// worker has finished. The job must not call planet_workers_run itself. A
// nil team (a bare Planetary_State) runs the job inline like an empty one.
planet_workers_run :: proc(team: ^Planet_Workers, job: Planet_Worker_Proc, data: rawptr) {
	assert(job != nil, "planet_workers_run: nil job")
	if team == nil || team.count == 0 {
		job(data, 0, 1, team)
		return
	}
	team.job = job
	team.data = data
	for worker in 0 ..< team.count do sync.post(&team.slots[worker].dispatch, 1)
	for _ in 0 ..< team.count do sync.wait(&team.complete)
}

// planet_workers_sync is a phase barrier inside a running job: every worker
// must reach it before any continues.
planet_workers_sync :: proc(team: ^Planet_Workers) {
	if team == nil || team.count == 0 do return
	_ = sync.barrier_wait(&team.barrier)
}

// planet_worker_range splits [0, total) into `workers` contiguous chunks and
// returns the chunk for `worker`; the last chunk absorbs the remainder.
planet_worker_range :: proc(worker, workers, total: int) -> (start, end: int) {
	assert(workers > 0 && worker >= 0 && worker < workers, "planet_worker_range: worker")
	assert(total >= 0, "planet_worker_range: total")
	per_worker := (total + workers - 1) / workers
	start = min(worker * per_worker, total)
	end = min(start + per_worker, total)
	return
}

@(private = "file")
_planet_worker_loop :: proc(slot: ^Planet_Worker_Slot) {
	team := slot.team
	for {
		sync.wait(&slot.dispatch)
		if sync.atomic_load(&team.shutdown) do return
		team.job(team.data, slot.worker, team.count, team)
		sync.post(&team.complete, 1)
	}
}

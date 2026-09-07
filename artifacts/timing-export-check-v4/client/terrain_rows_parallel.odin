#+build !js
package main

// Native row striping for the client-side terrain bakes. Every bake this
// drives writes disjoint row ranges of its output arrays and only reads
// immutable inputs, so the striped result is byte-identical to the serial one
// - the same guarantee shared/terrain_rows_parallel.odin relies on for the
// foundation bake.

import "core:sys/info"
import "core:thread"

TERRAIN_BAKE_MAX_WORKERS :: 16

@(private)
Terrain_Row_Job :: struct {
	data:      rawptr,
	work:      proc(data: rawptr, row_start, row_end: int),
	row_start: int,
	row_end:   int,
}

// terrain_bake_worker_count is the stripe width the budgeted bake loops
// advance by, so a budget slice does one row per core instead of one row.
terrain_bake_worker_count :: proc() -> int {
	_, logical, ok := info.cpu_core_count()
	if !ok do logical = 1
	return clamp(logical, 1, TERRAIN_BAKE_MAX_WORKERS)
}

// terrain_rows_parallel runs work over [row_start, row_end) split across
// workers. The serial fallback keeps a one-core machine - and any thread
// creation failure - correct rather than merely slower.
terrain_rows_parallel :: proc(
	row_start, row_end: int,
	data: rawptr,
	work: proc(data: rawptr, row_start, row_end: int),
) {
	assert(row_start <= row_end, "terrain_rows_parallel: bad range")
	assert(work != nil, "terrain_rows_parallel: nil work")
	rows := row_end - row_start
	if rows <= 0 do return
	worker_count := min(terrain_bake_worker_count(), rows)
	if worker_count <= 1 || rows < 8 {
		work(data, row_start, row_end)
		return
	}
	jobs: [TERRAIN_BAKE_MAX_WORKERS]Terrain_Row_Job
	threads: [TERRAIN_BAKE_MAX_WORKERS]^thread.Thread
	rows_per_worker := (rows + worker_count - 1) / worker_count
	spawned := 0
	for worker in 0 ..< worker_count {
		start := row_start + worker * rows_per_worker
		end := min(start + rows_per_worker, row_end)
		if start >= end do break
		jobs[worker] = {data = data, work = work, row_start = start, row_end = end}
		threads[worker] = thread.create_and_start_with_poly_data(
			&jobs[worker],
			proc(job: ^Terrain_Row_Job) {job.work(job.data, job.row_start, job.row_end)},
		)
		// Thread creation failed: run this stripe inline instead of dropping
		// it, which would leave a band of the bake unwritten.
		if threads[worker] == nil do work(data, start, end)
		spawned = worker + 1
	}
	for worker in 0 ..< spawned {
		if threads[worker] == nil do continue
		thread.join(threads[worker])
		thread.destroy(threads[worker])
	}
}

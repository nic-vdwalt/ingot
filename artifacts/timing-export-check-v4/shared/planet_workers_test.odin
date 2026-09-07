package shared

import "core:testing"

@(test)
planet_worker_range_partitions_exactly :: proc(t: ^testing.T) {
	for workers in 1 ..= PLANET_WORKERS_MAX {
		covered := 0
		previous_end := 0
		for worker in 0 ..< workers {
			start, end := planet_worker_range(worker, workers, PLANET_SIM_CELL_COUNT)
			testing.expect_value(t, start, previous_end)
			testing.expect(t, end >= start, "range must not be inverted")
			covered += end - start
			previous_end = end
		}
		testing.expect_value(t, covered, PLANET_SIM_CELL_COUNT)
		testing.expect_value(t, previous_end, PLANET_SIM_CELL_COUNT)
	}
	// Fewer items than workers: trailing workers get empty ranges.
	start, end := planet_worker_range(5, 6, 3)
	testing.expect_value(t, start, 3)
	testing.expect_value(t, end, 3)
}

@(private = "file")
Sum_Job :: struct {
	values: []u64,
	totals: [PLANET_WORKERS_MAX]u64,
	seen:   [PLANET_WORKERS_MAX]int,
}

@(private = "file")
_sum_job_run :: proc(data: rawptr, worker, workers: int, team: ^Planet_Workers) {
	job := (^Sum_Job)(data)
	start, end := planet_worker_range(worker, workers, len(job.values))
	for value in job.values[start:end] do job.totals[worker] += value
	planet_workers_sync(team)
	job.seen[worker] += 1
}

// The team runs each job once per worker, the barrier is usable inside a
// job, and the zero-worker team runs the same body inline as worker 0 of 1.
@(test)
planet_workers_run_every_worker_once_and_fall_back_inline :: proc(t: ^testing.T) {
	values := make([]u64, 1_000)
	defer delete(values)
	for &value, index in values do value = u64(index)
	expected := u64(len(values) * (len(values) - 1) / 2)

	team: Planet_Workers
	planet_workers_init(&team)
	defer planet_workers_deinit(&team)
	job := Sum_Job{values = values}
	for _ in 0 ..< 3 do planet_workers_run(&team, _sum_job_run, &job)
	total: u64
	for worker in 0 ..< max(team.count, 1) {
		total += job.totals[worker]
		testing.expect_value(t, job.seen[worker], 3)
	}
	testing.expect_value(t, total, expected * 3)

	serial: Planet_Workers
	serial_job := Sum_Job{values = values}
	planet_workers_run(&serial, _sum_job_run, &serial_job)
	testing.expect_value(t, serial.count, 0)
	testing.expect_value(t, serial_job.totals[0], expected)
	testing.expect_value(t, serial_job.seen[0], 1)
}

@(test)
planet_workers_are_joined_by_deinit :: proc(t: ^testing.T) {
	team: Planet_Workers
	planet_workers_init(&team)
	created := team.count
	planet_workers_deinit(&team)
	testing.expect_value(t, team.count, 0)
	for worker in 0 ..< created do testing.expect(t, team.threads[worker] == nil, "thread cleared")
	// Deinit on a team that never started is a no-op.
	planet_workers_deinit(&team)
	testing.expect_value(t, team.count, 0)
}

// Every planetary job must be partition-independent: the team result and
// the inline serial result are compared exactly across ocean, transport and
// climate dynamics over several cadence steps.
@(test)
planetary_team_jobs_match_serial_inline_execution :: proc(t: ^testing.T) {
	parallel := new(World)
	serial := new(World)
	defer free(parallel)
	defer free(serial)
	testing.expect(t, world_init_seed(parallel, TERRAIN_SEED))
	defer world_deinit(parallel)
	testing.expect(t, world_init_seed(serial, TERRAIN_SEED))
	defer world_deinit(serial)
	testing.expect(t, parallel.planetary.workers.count > 0, "team should have workers")
	planet_workers_deinit(serial.planetary.workers)
	testing.expect_value(t, serial.planetary.workers.count, 0)
	for tick in u64(0) ..< PLANET_CLIMATE_CADENCE_TICKS * 6 {
		world_planetary_step(parallel, tick)
		world_planetary_step(serial, tick)
	}
	climate_test_expect_state_equal(t, &parallel.planetary.climate, &serial.planetary.climate)
	for value, index in parallel.planetary.ocean.surface_mm {
		testing.expect_value(t, value, serial.planetary.ocean.surface_mm[index])
	}
	for value, index in parallel.planetary.ocean.transport_east {
		testing.expect_value(t, value, serial.planetary.ocean.transport_east[index])
	}
	for value, index in parallel.planetary.ocean.deep_transport_north {
		testing.expect_value(t, value, serial.planetary.ocean.deep_transport_north[index])
	}
	parallel_fields := biogeochemistry_fields(&parallel.planetary.biogeochemistry)
	serial_fields := biogeochemistry_fields(&serial.planetary.biogeochemistry)
	for field, field_index in parallel_fields {
		for value, index in field {
			testing.expect_value(t, value, serial_fields[field_index][index])
		}
	}
	testing.expect_value(
		t,
		parallel.planetary.biogeochemistry.diagnostics.transport_residual,
		serial.planetary.biogeochemistry.diagnostics.transport_residual,
	)
}

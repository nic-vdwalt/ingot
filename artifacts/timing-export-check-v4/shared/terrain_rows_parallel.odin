#+build !js
package shared

// Native implementation of the foundation row bake: rows are independent
// pure functions of (recipe, row), so the row range is striped across worker
// threads. Each stripe writes disjoint index ranges of the output slices,
// so the result is bit-identical to the serial path regardless of thread
// scheduling - the deterministic sim sees the same world either way.

import "core:sys/info"
import "core:thread"
import procgen "ingot:procgen"

FOUNDATION_MAX_WORKERS :: 16

@(private)
Foundation_Row_Job :: struct {
	field:     ^Foundation_Field,
	recipe:    ^procgen.Terrain_Recipe_V3,
	raw:       []procgen.Terrain_Biome_Blend_V2,
	row_start: int,
	row_end:   int,
	ok:        bool,
}

@(private)
_foundation_rows_generate :: proc(
	field: ^Foundation_Field,
	recipe: ^procgen.Terrain_Recipe_V3,
	raw_biomes: []procgen.Terrain_Biome_Blend_V2,
) -> bool {
	_, logical, count_ok := info.cpu_core_count()
	if !count_ok do logical = 1
	worker_count := clamp(logical, 1, FOUNDATION_MAX_WORKERS)
	if worker_count <= 1 {
		return _foundation_row_range(field, recipe, raw_biomes, 0, HEIGHTFIELD_RESOLUTION)
	}
	jobs: [FOUNDATION_MAX_WORKERS]Foundation_Row_Job
	threads: [FOUNDATION_MAX_WORKERS]^thread.Thread
	rows_per_worker := (HEIGHTFIELD_RESOLUTION + worker_count - 1) / worker_count
	spawned := 0
	for worker in 0 ..< worker_count {
		row_start := worker * rows_per_worker
		row_end := min(row_start + rows_per_worker, HEIGHTFIELD_RESOLUTION)
		if row_start >= row_end do break
		jobs[worker] = {
			field     = field,
			recipe    = recipe,
			raw       = raw_biomes,
			row_start = row_start,
			row_end   = row_end,
		}
		threads[worker] = thread.create_and_start_with_poly_data(
			&jobs[worker],
			proc(job: ^Foundation_Row_Job) {
				job.ok = _foundation_row_range(
					job.field,
					job.recipe,
					job.raw,
					job.row_start,
					job.row_end,
				)
			},
		)
		if threads[worker] == nil {
			// Thread creation failed: run this stripe inline instead.
			jobs[worker].ok = _foundation_row_range(field, recipe, raw_biomes, row_start, row_end)
		}
		spawned = worker + 1
	}
	ok := true
	for worker in 0 ..< spawned {
		if threads[worker] != nil {
			thread.join(threads[worker])
			thread.destroy(threads[worker])
		}
		ok &&= jobs[worker].ok
	}
	return ok
}

package main

// Client-side bake benchmarks. _climate_bake_row and _albedo_bake_row touch
// no GPU state, so they can be driven against a heap-allocated Terrain with
// no graphics context. These are the before/after numbers for the parallel
// bake work on the per-face planet albedo.
//
//   bash build.sh bench
//
// Gated behind FORGE_BENCH: a full bake is multi-second and the normal
// test suite must stay fast.

import shared "../shared"
import "core:fmt"
import "core:testing"
import "core:time"

BENCH_ENABLED :: #config(FORGE_BENCH, false)
BENCH_REPEATS :: 3

// _bench_n reports the best of `repeats` runs. The heaviest bakes use one
// repeat: at 6.3M texels they are slow enough that repeating them buys less
// than it costs.
_bench_n :: proc(name: string, repeats: int, work: proc()) {
	assert(work != nil, "_bench_n: nil work")
	assert(repeats > 0, "_bench_n: repeats must be positive")
	best := max(time.Duration)
	for _ in 0 ..< repeats {
		start := time.tick_now()
		work()
		elapsed := time.tick_since(start)
		if elapsed < best do best = elapsed
	}
	fmt.printf("[bench] %-34s %9.2f ms\n", name, time.duration_milliseconds(best))
}

_bench :: proc(name: string, work: proc()) {
	_bench_n(name, BENCH_REPEATS, work)
}

// Keeps the suite non-empty (ODIN_TEST_FAIL_ON_EMPTY) and documents how to
// turn the real benchmarks on when they are compiled out.
@(test)
bench_client_harness_reports_state :: proc(t: ^testing.T) {
	// Also pins the planet scale the benchmark comments quote, so a change
	// to the face resolution shows up here instead of silently invalidating
	// them.
	testing.expect_value(t, shared.PLANET_FACE_RESOLUTION, 769)
	testing.expect_value(t, PLANET_ALBEDO_SIZE, 1024)
	testing.expect_value(t, PLANET_ALBEDO_ROWS, 6144)
	when BENCH_ENABLED {
		testing.expect(t, BENCH_REPEATS > 0, "bench_client_harness: repeats must be positive")
	} else {
		testing.expect(t, !BENCH_ENABLED, "bench_client_harness: disabled without the define")
	}
}

when BENCH_ENABLED {
	@(private = "file")
	bench_terrain: ^Terrain
	@(private = "file")
	bench_world: ^shared.World
	@(private = "file")
	bench_nearshore: ^Ocean_Nearshore

	@(test)
	bench_terrain_bakes :: proc(t: ^testing.T) {
		world := new(shared.World)
		defer free(world)
		testing.expect(t, shared.world_init_seed(world, shared.TERRAIN_SEED), "world init")
		defer shared.world_deinit(world)
		// ~100 MB; heap, never the stack.
		terrain := new(Terrain)
		defer free(terrain)
		// terrain_init_begin needs a physics world and a GPU context, so the
		// scalars the albedo bake reads are set directly instead.
		terrain.world_ref = world
		terrain.sea_level = f32(world.foundation.sea_level) / f32(shared.HEIGHT_DELTA_SCALE)
		terrain.snow_level = f32(world.foundation.snow_level) / f32(shared.HEIGHT_DELTA_SCALE)
		bench_terrain, bench_world = terrain, world

		_bench_n("climate bake 6144 rows", 1, proc() {
			_climate_bake_rows(bench_terrain, bench_world, 0, PLANET_ALBEDO_ROWS)
		})
		// _albedo_bake_row asserts the climate cache is complete.
		bench_terrain.climate_row = PLANET_ALBEDO_ROWS
		_bench_n("albedo bake 6144 rows", 1, proc() {
			_albedo_bake_rows(bench_terrain, bench_world, 0, PLANET_ALBEDO_ROWS)
		})
		_bench("patch rebuild one", proc() {
			patch := &bench_terrain.planet_patches[0]
			patch.face = .Pos_X
			patch.patch_u = 3
			patch.patch_v = 3
			_ = planet_render_patch_generate(patch, bench_world)
		})
		_bench("planetary atmosphere dynamics", proc() {
			shared.climate_dynamics_step(&bench_world.planetary)
		})
		_bench("atmosphere wind substep", proc() {
			shared.climate_wind_substep(&bench_world.planetary)
		})
		_bench("atmosphere mass transport", proc() {
			shared.climate_mass_transport_substep(&bench_world.planetary)
		})
		_bench("atmosphere scalar transport", proc() {
			shared.climate_scalar_transport_substep(&bench_world.planetary)
		})
		_bench("planetary ocean step", proc() {
			shared.ocean_step(&bench_world.planetary)
		})
		_bench("biogeochemistry transport", proc() {
			shared.biogeochemistry_transport_step(&bench_world.planetary)
		})
		nearshore := new(Ocean_Nearshore)
		defer free(nearshore)
		bench_nearshore = nearshore
		_bench("nearshore rebuild 96x96", proc() {
			ocean_nearshore_rebuild(bench_nearshore, bench_world, {1, 0, 0})
		})
		fmt.printf("[bench] %-34s %9d cells\n", "nearshore work", OCEAN_NEARSHORE_COUNT)
		fmt.printf(
			"[bench] %-34s %9d edges\n",
			"planet canonical edges",
			len(bench_world.planetary.grid.canonical_edges),
		)
		fmt.printf(
			"[bench] %-34s %9d fluxes\n",
			"nearshore HLL per substep",
			2 * OCEAN_NEARSHORE_EDGE * OCEAN_NEARSHORE_CELLS,
		)
		fmt.printf("[bench] %-34s %9d vertices\n", "clipmap ring work", OCEAN_CLIPMAP_VERTICES)
		fmt.printf(
			"[bench] %-34s %9d arrows\n",
			"wind mode work",
			WIND_CLOSE_CAPACITY + WIND_REGIONAL_CAPACITY + WIND_OVERVIEW_CAPACITY,
		)
		fmt.printf(
			"[bench] %-34s %9d arrows\n",
			"currents mode work",
			2 * (WIND_CLOSE_CAPACITY + WIND_REGIONAL_CAPACITY + WIND_OVERVIEW_CAPACITY),
		)
		// Terraforming latches heightfield.modified on for good, so every
		// later delta lookup pays a real bilinear blend instead of the
		// zero-delta early-out. This must stay the LAST bench in this proc:
		// it mutates the shared bench_world, and the benches above are all
		// calibrated against an untouched one.
		shared.planet_heightfield_apply(
			&bench_world.heightfield,
			{.Pos_X, shared.PLANET_FACE_CELLS / 2, shared.PLANET_FACE_CELLS / 2},
			1,
		)
		_bench_n("albedo bake 6144 rows terraformed", 1, proc() {
			_albedo_bake_rows(bench_terrain, bench_world, 0, PLANET_ALBEDO_ROWS)
		})
		testing.expect(t, bench_terrain.climate_row == PLANET_ALBEDO_ROWS, "bake ran")
	}

	@(private = "file")
	bench_flora: ^Flora
	@(private = "file")
	bench_ruins: ^Ruins
	@(private = "file")
	bench_center_tile: Flora_Tile_Id

	// The flora rescatter is what a stream-tile crossing pays in a single
	// frame. Scatter does cast a Box3D ray per kept candidate in production;
	// it is benchmarkable here only because terrain_seat_height falls back to
	// the foundation heights when there is no physics world. The number below
	// is therefore the placement cost without the raycasts.
	@(test)
	bench_flora_scatter :: proc(t: ^testing.T) {
		world := new(shared.World)
		defer free(world)
		testing.expect(t, shared.world_init_seed(world, shared.TERRAIN_SEED), "world init")
		defer shared.world_deinit(world)
		terrain := new(Terrain)
		defer free(terrain)
		terrain.world_ref = world
		terrain.sea_level = f32(world.foundation.sea_level) / f32(shared.HEIGHT_DELTA_SCALE)
		terrain.snow_level = f32(world.foundation.snow_level) / f32(shared.HEIGHT_DELTA_SCALE)
		flora := new(Flora)
		defer free(flora)
		ruins := new(Ruins)
		defer free(ruins)
		bench_terrain, bench_world = terrain, world
		bench_flora, bench_ruins = flora, ruins
		// The spawn-face centre, resolved through the same seam the game uses.
		bench_center_tile = flora_world_tile({1, 0, 0})
		_bench("flora scatter full window", proc() {
			_flora_scatter_pooled(
				bench_flora,
				bench_terrain,
				bench_world,
				bench_ruins,
				bench_center_tile,
			)
		})
		fmt.printf("[bench] %-34s %9d instances\n", "flora scatter yield", bench_flora.count)
		testing.expect(t, bench_flora.count > 0, "scatter produced instances")
		testing.expect(t, bench_flora.tile_count > 0, "scatter recorded tile spans")
		// The span bookkeeping must account for every instance exactly once,
		// or the coarse cull silently drops flora.
		covered := 0
		for slot in 0 ..< bench_flora.tile_count {
			span := bench_flora.tiles[slot]
			covered += int(span.large_end - span.large_begin)
			covered += int(span.ground_end - span.ground_begin)
		}
		testing.expect_value(t, covered, bench_flora.count)
	}
}

package shared

// Cadence-class tick benchmarks. The authoritative tick runs at 4 Hz inside
// a render frame, so its tail (not its best case) is what shows up as frame
// p95/p99. This reports the distribution of complete-tick and per-stage cost
// after warm-up, split by the cadence class each tick falls into:
//
//   ordinary   tick % 2 != 0              climate dynamics only
//   even       tick % 4 != 0, % 2 == 0    + ocean, transport, waves
//   climate    tick % 4 == 0, % 12 != 0   + climate, sea ice, biogeo, diagnostics
//   ecology    tick % 12 == 0             + flora ecology
//   geology    tick 1152                  + tectonics/geology bundle (once)
//
// Gated behind FORGE_BENCH like bench_test.odin: the full world costs seconds
// to build.

import "core:fmt"
import "core:slice"
import "core:testing"

BENCH_TICK_WARMUP :: u64(48)
BENCH_TICK_WINDOW :: u64(240)

Bench_Tick_Class :: enum u8 {
	Ordinary,
	Even,
	Climate,
	Ecology,
}

BENCH_TICK_CLASS_NAMES :: [Bench_Tick_Class]string {
	.Ordinary = "ordinary",
	.Even     = "even",
	.Climate  = "climate",
	.Ecology  = "ecology",
}

bench_tick_class :: proc(tick: u64) -> Bench_Tick_Class {
	if tick % FLORA_ECOLOGY_CADENCE_TICKS == 0 do return .Ecology
	if tick % PLANET_CLIMATE_CADENCE_TICKS == 0 do return .Climate
	if tick % PLANET_OCEAN_CADENCE_TICKS == 0 do return .Even
	return .Ordinary
}

@(private = "file")
_bench_percentile :: proc(sorted: []f64, percentile: int) -> f64 {
	if len(sorted) == 0 do return 0
	index := clamp((len(sorted) * percentile + 99) / 100 - 1, 0, len(sorted) - 1)
	return sorted[index]
}

@(private = "file")
_bench_distribution_row :: proc(name: string, values: []f64) {
	if len(values) == 0 do return
	sorted := slice.clone(values, context.temp_allocator)
	slice.sort(sorted)
	fmt.printf(
		"[bench] %-28s n=%3d  p50 %7.3f  p95 %7.3f  max %7.3f ms\n",
		name,
		len(sorted),
		_bench_percentile(sorted, 50),
		_bench_percentile(sorted, 95),
		sorted[len(sorted) - 1],
	)
}

@(test)
bench_tick_class_is_stable :: proc(t: ^testing.T) {
	testing.expect_value(t, bench_tick_class(1), Bench_Tick_Class.Ordinary)
	testing.expect_value(t, bench_tick_class(2), Bench_Tick_Class.Even)
	testing.expect_value(t, bench_tick_class(4), Bench_Tick_Class.Climate)
	testing.expect_value(t, bench_tick_class(12), Bench_Tick_Class.Ecology)
	testing.expect_value(t, bench_tick_class(24), Bench_Tick_Class.Ecology)
}

when BENCH_ENABLED {
	@(test)
	bench_sim_tick_cadence_classes :: proc(t: ^testing.T) {
		world := new(World)
		defer free(world)
		testing.expect(t, world_init_seed(world, TERRAIN_SEED), "bench_sim_tick: world init")
		defer world_deinit(world)
		timing: Sim_Tick_Timing
		// Warm-up covers tick zero (every cadence branch plus geology) and the
		// initial waterfield settle; neither is steady state.
		for tick in u64(0) ..< BENCH_TICK_WARMUP {
			sim_tick(world, tick, &timing)
		}
		totals: [Bench_Tick_Class][dynamic]f64
		stages: [Sim_Stage][dynamic]f64
		defer for class in Bench_Tick_Class do delete(totals[class])
		defer for stage in Sim_Stage do delete(stages[stage])
		for tick in BENCH_TICK_WARMUP ..< BENCH_TICK_WARMUP + BENCH_TICK_WINDOW {
			sim_tick(world, tick, &timing)
			append(&totals[bench_tick_class(tick)], timing.total_ms)
			for stage in Sim_Stage {
				if timing.stage_ms[stage] > 0 do append(&stages[stage], timing.stage_ms[stage])
			}
		}
		class_names := BENCH_TICK_CLASS_NAMES
		for class in Bench_Tick_Class {
			_bench_distribution_row(fmt.tprintf("tick %s", class_names[class]), totals[class][:])
		}
		stage_names := SIM_STAGE_NAMES
		for stage in Sim_Stage {
			_bench_distribution_row(fmt.tprintf("stage %s", stage_names[stage]), stages[stage][:])
		}
		// Geology runs every 1,152 ticks; measure that class once on the
		// settled world rather than simulating 1,152 ticks to reach it.
		sim_tick(world, PLANET_GEOLOGY_CADENCE_TICKS, &timing)
		fmt.printf(
			"[bench] %-28s total %7.3f  geology %7.3f  diagnostics %7.3f ms\n",
			"tick geology (1152)",
			timing.total_ms,
			timing.stage_ms[.Geology],
			timing.stage_ms[.Diagnostics],
		)
		testing.expect(t, len(totals[.Climate]) > 0, "bench_sim_tick: no climate ticks")
	}

	// Sub-step attribution for the two heaviest planetary systems on a
	// settled world. Each row is one call after warm-up, measured in the
	// order the owning step runs them so state is representative.
	@(test)
	bench_planetary_substeps :: proc(t: ^testing.T) {
		world := new(World)
		defer free(world)
		testing.expect(t, world_init_seed(world, TERRAIN_SEED), "bench_planetary_substeps: init")
		defer world_deinit(world)
		for tick in u64(0) ..< BENCH_TICK_WARMUP do sim_tick(world, tick)
		planet := &world.planetary
		Substep :: struct {
			name: string,
			run:  proc(planet: ^Planetary_State),
		}
		substeps := [?]Substep {
			{"waves.wind_sea", proc(planet: ^Planetary_State) {waves_wind_sea_step(planet)}},
			{"waves.bathymetry", proc(planet: ^Planetary_State) {waves_derive_bathymetry(planet)}},
			{"waves.storm_sources", proc(planet: ^Planetary_State) {waves_detect_storm_sources(planet)}},
			{"waves.emit_packets", proc(planet: ^Planetary_State) {waves_emit_swell_packets(planet)}},
			{"waves.begin_breaker", proc(planet: ^Planetary_State) {waves_begin_breaker_step(&planet.waves)}},
			{"waves.packets_step", proc(planet: ^Planetary_State) {waves_swell_packets_step(planet)}},
			{"waves.rasterize", proc(planet: ^Planetary_State) {waves_rasterize_packets(planet)}},
			{"waves.combine", proc(planet: ^Planetary_State) {waves_combine_components(planet)}},
			{"climate.radiation", proc(planet: ^Planetary_State) {_ = climate_radiation_step(planet)}},
			{"climate.thermal_pressure", proc(planet: ^Planetary_State) {
				total: i64
				for index in 0 ..< PLANET_SIM_CELL_COUNT do total += i64(planet.climate.temperature[index])
				climate_thermal_pressure_step(planet, total)
			}},
			{"climate.moisture", proc(planet: ^Planetary_State) {climate_moisture_step(planet)}},
			{"sea_ice", proc(planet: ^Planetary_State) {sea_ice_step(planet)}},
			{"biogeo.radiation", proc(planet: ^Planetary_State) {biogeochemistry_radiation_step(planet)}},
			{"biogeo.reaction", proc(planet: ^Planetary_State) {biogeochemistry_reaction_step(planet)}},
			{"ocean", proc(planet: ^Planetary_State) {ocean_step(planet)}},
			{"biogeo.transport", proc(planet: ^Planetary_State) {biogeochemistry_transport_step(planet)}},
		}
		samples: [len(substeps)][dynamic]f64
		defer for &list in samples do delete(list)
		for _ in 0 ..< 16 {
			for substep, index in substeps {
				timing: Sim_Tick_Timing
				sim_timing_begin(&timing, 0)
				substep.run(planet)
				sim_timing_end(&timing)
				append(&samples[index], timing.total_ms)
			}
		}
		for substep, index in substeps do _bench_distribution_row(substep.name, samples[index][:])
		testing.expect(t, len(samples[0]) == 16, "bench_planetary_substeps: no samples")
	}
}

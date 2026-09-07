package shared

import "core:mem"
import ecs "ingot:ecs"

PLANET_CLIMATE_CADENCE_TICKS :: u64(4)
PLANET_ATMOSPHERE_DYNAMICS_CADENCE_TICKS :: u64(1)
PLANET_OCEAN_CADENCE_TICKS :: u64(2)
PLANET_WAVE_CADENCE_TICKS :: PLANET_OCEAN_CADENCE_TICKS
PLANET_GEOLOGY_CADENCE_TICKS :: u64(1_152)
PLANET_TECTONIC_CADENCE_TICKS :: PLANET_GEOLOGY_CADENCE_TICKS
PLANET_DIAGNOSTIC_STRIDE :: 16
#assert(PLANET_SIM_CELL_COUNT % PLANET_DIAGNOSTIC_STRIDE == 0)

Planet_Diagnostics :: struct {
	mean_temperature_mk:  i32,
	mean_pressure_pa:     u32,
	mean_humidity:        u32,
	mean_precipitation:   u32,
	mean_wind_speed:      u32,
	mean_current_speed:   u32,
	mean_tide_abs_mm:     u32,
	mean_wave_height_mm:  u32,
	mean_crust_age_ka:    u32,
	mean_heat_flux_mw_m2: u32,
	active_volcanoes:     u16,
	active_vents:         u16,
	dormant_vents:        u16,
	extinct_vents:        u16,
	mean_surface_par:     u32,
	mean_benthic_par:     u32,
	oxygenated_cells:     u32,
	anoxic_cells:         u32,
	steps:                u64,
}

Planetary_Diagnostics_Accum :: struct {
	temperature:            i64,
	pressure:               i64,
	humidity:               i64,
	rain:                   i64,
	wind:                   u64,
	current:                u64,
	tide:                   u64,
	wave:                   u64,
	age:                    u64,
	heat:                   u64,
	surface_par:            u64,
	benthic_par:            u64,
	oxygenated:             u32,
	anoxic:                 u32,
	total_oxygen:           u64,
	total_inorganic_carbon: u64,
	total_sulfide:          u64,
	total_phosphate:        u64,
}

Planetary_State :: struct {
	physical:     Planet_Physical_Parameters,
	grid:         Planet_Sim_Grid,
	// workers is the shared persistent team; a shadow state (planetary
	// shadow) reuses the live world's team through this pointer, so it is
	// owned by the state that created it (workers_owned).
	workers:      ^Planet_Workers,
	workers_owned: bool,
	// mutation_revision counts edits to the simulated state made outside
	// the planetary step (terraform bathymetry sync, debug weather tools,
	// snapshot restore). An asynchronously prepared step is only committed
	// when the revision it started from is still current.
	mutation_revision: u64,
	orbit:        Orbit_State,
	climate:      Climate_State,
	ocean:        Ocean_State,
	biogeochemistry: Biogeochemistry_State,
	waves:       Wave_State,
	geology:        Geology_State,
	tectonics:      Tectonic_State,
	geomorphology:  Geomorphology_State,
	volcanism:      Volcanism_State,
	events:      Planetary_Event_Queue,
	diagnostics:       Planet_Diagnostics,
	diagnostics_accum: Planetary_Diagnostics_Accum,
}

planetary_init :: proc(state: ^Planetary_State, world: ^World, allocator := context.allocator) {
	assert(state != nil && world != nil, "planetary_init: nil input")
	state^ = {}
	state.physical = planet_physical_earthlike()
	planet_sim_grid_init(&state.grid, state.physical, allocator)
	state.workers = new(Planet_Workers, allocator)
	state.workers_owned = true
	planet_workers_init(state.workers, planet_workers_default_count())
	orbit_init(&state.orbit, world.foundation.seed)
	geology_init(&state.geology, &world.foundation, allocator)
	tectonics_init(&state.tectonics, &world.foundation, allocator)
	geomorphology_init(&state.geomorphology, allocator)
	ocean_init(&state.ocean, world, allocator)
	climate_init(&state.climate, world, allocator)
	biogeochemistry_init(&state.biogeochemistry, state, world.foundation.seed, allocator)
	waves_init(&state.waves, allocator)
	volcanism_init(&state.volcanism, &state.geology, allocator)
}

planetary_deinit :: proc(state: ^Planetary_State, allocator := context.allocator) {
	assert(state != nil, "planetary_deinit: nil state")
	volcanism_deinit(&state.volcanism, allocator)
	waves_deinit(&state.waves, allocator)
	biogeochemistry_deinit(&state.biogeochemistry, allocator)
	climate_deinit(&state.climate, allocator)
	ocean_deinit(&state.ocean, allocator)
	geomorphology_deinit(&state.geomorphology, allocator)
	tectonics_deinit(&state.tectonics, allocator)
	geology_deinit(&state.geology, allocator)
	if state.workers_owned && state.workers != nil {
		planet_workers_deinit(state.workers)
		free(state.workers, allocator)
	}
	planet_sim_grid_deinit(&state.grid, allocator)
	state^ = {}
}

// planetary_mark_mutated must be called by every writer of the simulated
// planetary state that is not the planetary step itself.
planetary_mark_mutated :: proc(state: ^Planetary_State) {
	assert(state != nil, "planetary_mark_mutated: nil state")
	state.mutation_revision += 1
}

// world_planetary_step is one planetary tick: the simulated stage (a pure
// function of the Planetary_State, so it can run ahead on a shadow copy)
// followed by the world stage (geology and diagnostics, which read and
// write the wider World).
world_planetary_step :: proc(world: ^World, tick: u64, timing: ^Sim_Tick_Timing = nil) {
	assert(world != nil, "world_planetary_step: nil world")
	planetary_step_simulated(&world.planetary, tick, timing)
	planetary_step_world(world, tick, timing)
}

// planetary_step_simulated advances orbit, atmosphere, ocean, biogeochemistry
// and waves. It reads and writes only `state`, which is what lets the client
// prepare it asynchronously on a shadow state.
planetary_step_simulated :: proc(state: ^Planetary_State, tick: u64, timing: ^Sim_Tick_Timing = nil) {
	assert(state != nil, "planetary_step_simulated: nil state")
	orbit_step(&state.orbit, state.physical, PLANET_SIM_SECONDS_PER_TICK)
	planetary_events_clear(&state.events)
	if tick % PLANET_ATMOSPHERE_DYNAMICS_CADENCE_TICKS == 0 {
		climate_dynamics_step(state)
	}
	sim_timing_mark(timing, .Climate_Dynamics)
	if tick % PLANET_CLIMATE_CADENCE_TICKS == 0 {
		// One fused worker-team job for climate, sea ice and biogeochemistry;
		// climate_step / sea_ice_step / biogeochemistry_step are its serial
		// reference. Its cost is attributed to the Climate stage.
		climate_cadence_step(state)
		sim_timing_mark(timing, .Climate)
	}
	if tick % PLANET_OCEAN_CADENCE_TICKS == 0 {
		ocean_step(state)
		sim_timing_mark(timing, .Ocean)
		biogeochemistry_transport_step(state)
		sim_timing_mark(timing, .Biogeochemistry_Transport)
	}
	if tick % PLANET_WAVE_CADENCE_TICKS == 0 {
		waves_step(state)
		sim_timing_mark(timing, .Waves)
	}
	if tick % PLANET_CLIMATE_CADENCE_TICKS == 0 {
		planetary_diagnostics_accumulate(state)
	}
}

// world_planetary_commit installs a planetary state whose simulated stage
// was already advanced to `tick` (on a shadow, see planetary_shadow.odin)
// and then runs the world stage, so the result equals world_planetary_step.
world_planetary_commit :: proc(
	world: ^World,
	tick: u64,
	prepared: ^Planetary_State,
	scratch: ^Planetary_State,
	timing: ^Sim_Tick_Timing = nil,
) {
	assert(world != nil && prepared != nil && scratch != nil, "world_planetary_commit: nil argument")
	planetary_shadow_swap(&world.planetary, prepared, scratch)
	sim_timing_mark(timing, .Planetary_Commit)
	planetary_step_world(world, tick, timing)
}

// planetary_step_world runs the stages that touch the World beyond the
// planetary state: the geology bundle on its cadence and the diagnostics.
planetary_step_world :: proc(world: ^World, tick: u64, timing: ^Sim_Tick_Timing = nil) {
	assert(world != nil, "planetary_step_world: nil world")
	state := &world.planetary
	if tick % PLANET_GEOLOGY_CADENCE_TICKS == 0 {
		years := tectonics_years_per_step(state.tectonics.mode)
		_ = planetary_geological_step(world, years)
		sim_timing_mark(timing, .Geology)
	}
	if tick % PLANET_CLIMATE_CADENCE_TICKS == 0 {
		if tick % PLANET_GEOLOGY_CADENCE_TICKS == 0 {
			planetary_diagnostics_accumulate(state)
		}
		biome_environment_step(world, tick)
		planetary_diagnostics_finalize(world)
		sim_timing_mark(timing, .Diagnostics)
	}
}

planetary_geological_step :: proc(world: ^World, years: u32) -> bool {
	if !tectonics_step(world, years) do return false
	state := &world.planetary
	_ = geomorphology_step(world, years)
	tectonics_mark_changed(&state.tectonics)
	_ = tectonics_publish_dirty_tiles(world)
	geology_tectonic_step(&state.geology, &state.tectonics)
	geothermal_step(state)
	ocean_geothermal_step(state)
	volcanism_step(state)
	volcanism_apply_lava(world)
	volcanism_reconcile(world)
	_ = hydrothermal_reconcile(world)
	hydrothermal_step(world)
	biome_environment_rebuild(world)
	return true
}

world_planetary_summary :: proc(world: ^World) -> Planetary_Summary {
	assert(world != nil, "world_planetary_summary: nil world")
	diagnostics := &world.planetary.diagnostics
	return {
		temperature_mk = diagnostics.mean_temperature_mk,
		pressure_pa = diagnostics.mean_pressure_pa,
		humidity = diagnostics.mean_humidity,
		precipitation = diagnostics.mean_precipitation,
		wind_speed = diagnostics.mean_wind_speed,
		current_speed = diagnostics.mean_current_speed,
		tide_mm = diagnostics.mean_tide_abs_mm,
		wave_height_mm = diagnostics.mean_wave_height_mm,
		crust_age_ka = diagnostics.mean_crust_age_ka,
		heat_flux_mw_m2 = diagnostics.mean_heat_flux_mw_m2,
		volcanoes = diagnostics.active_volcanoes,
		vents = diagnostics.active_vents,
		dormant_vents = diagnostics.dormant_vents,
		extinct_vents = diagnostics.extinct_vents,
		surface_par = diagnostics.mean_surface_par,
		benthic_par = diagnostics.mean_benthic_par,
		oxygenated = diagnostics.oxygenated_cells,
		anoxic = diagnostics.anoxic_cells,
		diagnostic_steps = diagnostics.steps,
	}
}

planetary_diagnostics_accumulate :: proc(state: ^Planetary_State) {
	assert(state != nil, "planetary_diagnostics_accumulate: nil state")
	accum: Planetary_Diagnostics_Accum
	for sample_index in 0 ..< PLANET_SIM_CELL_COUNT / PLANET_DIAGNOSTIC_STRIDE {
		index := sample_index * PLANET_DIAGNOSTIC_STRIDE
		accum.temperature += i64(state.climate.temperature[index])
		accum.pressure += i64(state.climate.pressure[index])
		accum.humidity += i64(state.climate.vapour[index])
		accum.rain += i64(state.climate.precipitation[index])
		accum.wind += u64(abs(state.climate.wind_east[index]) + abs(state.climate.wind_north[index]))
		accum.current += u64(
			abs(state.ocean.transport_east[index]) + abs(state.ocean.transport_north[index]),
		)
		accum.tide += u64(abs(state.ocean.surface_mm[index]))
		accum.wave += u64(state.waves.height_mm[index])
		accum.age += u64(state.geology.crust_age_ka[index])
		accum.heat += u64(state.geology.heat_flux_mw_m2[index])
		accum.surface_par += u64(state.biogeochemistry.surface_par[index])
		accum.benthic_par += u64(state.biogeochemistry.benthic_par[index])
		if state.ocean.mean_depth_mm[index] > 0 {
			if state.biogeochemistry.dissolved_oxygen[index] >= 20_000 do accum.oxygenated += 1
			else do accum.anoxic += 1
		}
	}
	accum.total_oxygen = biogeochemistry_field_total(state.biogeochemistry.dissolved_oxygen)
	accum.total_inorganic_carbon = biogeochemistry_field_total(state.biogeochemistry.dissolved_inorganic_carbon)
	accum.total_sulfide = biogeochemistry_field_total(state.biogeochemistry.hydrogen_sulfide)
	accum.total_phosphate = biogeochemistry_field_total(state.biogeochemistry.phosphate)
	state.diagnostics_accum = accum
}

planetary_diagnostics_finalize :: proc(world: ^World) {
	assert(world != nil, "planetary_diagnostics_finalize: nil world")
	state := &world.planetary
	accum := &state.diagnostics_accum
	count := i64(PLANET_SIM_CELL_COUNT / PLANET_DIAGNOSTIC_STRIDE)
	dormant_vents, extinct_vents: u16
	for vent in world.hydrothermal_vents.items {
		if vent.state == .Dormant do dormant_vents += 1
		if vent.state == .Extinct do extinct_vents += 1
	}
	state.biogeochemistry.diagnostics.total_oxygen = accum.total_oxygen
	state.biogeochemistry.diagnostics.total_inorganic_carbon = accum.total_inorganic_carbon
	state.biogeochemistry.diagnostics.total_sulfide = accum.total_sulfide
	state.biogeochemistry.diagnostics.total_phosphate = accum.total_phosphate
	state.biogeochemistry.diagnostics.oxygenated_cells = accum.oxygenated
	state.biogeochemistry.diagnostics.anoxic_cells = accum.anoxic
	state.biogeochemistry.diagnostics.mean_surface_par = u32(accum.surface_par / u64(count))
	state.biogeochemistry.diagnostics.mean_benthic_par = u32(accum.benthic_par / u64(count))
	state.biogeochemistry.diagnostics.steps += 1
	state.diagnostics = {
		mean_temperature_mk  = i32(accum.temperature / count),
		mean_pressure_pa     = u32(accum.pressure / count),
		mean_humidity        = u32(accum.humidity / count),
		mean_precipitation   = u32(accum.rain / count),
		mean_wind_speed      = u32(accum.wind / u64(count)),
		mean_current_speed   = u32(accum.current / u64(count)),
		mean_tide_abs_mm     = u32(accum.tide / u64(count)),
		mean_wave_height_mm  = u32(accum.wave / u64(count)),
		mean_crust_age_ka    = u32(accum.age / u64(count)),
		mean_heat_flux_mw_m2 = u32(accum.heat / u64(count)),
		active_volcanoes     = state.volcanism.count,
		active_vents         = u16(ecs.set_len(&world.hydrothermal_vents)) - dormant_vents - extinct_vents,
		dormant_vents        = dormant_vents,
		extinct_vents        = extinct_vents,
		mean_surface_par     = u32(accum.surface_par / u64(count)),
		mean_benthic_par     = u32(accum.benthic_par / u64(count)),
		oxygenated_cells     = accum.oxygenated,
		anoxic_cells         = accum.anoxic,
		steps                = state.diagnostics.steps + 1,
	}
}

planetary_diagnostics_update :: proc(world: ^World) {
	assert(world != nil, "planetary_diagnostics_update: nil world")
	planetary_diagnostics_accumulate(&world.planetary)
	planetary_diagnostics_finalize(world)
}

planetary_sample_index :: proc(direction: [3]f32) -> int {
	face, u, v := planet_locate(direction)
	stride := f32(PLANET_FACE_CELLS) / f32(PLANET_SIM_FACE_CELLS)
	coord := Planet_Sim_Coord {
		face,
		clamp(i32(u / stride), 0, i32(PLANET_SIM_FACE_CELLS - 1)),
		clamp(i32(v / stride), 0, i32(PLANET_SIM_FACE_CELLS - 1)),
	}
	return planet_sim_index(coord)
}

planetary_snapshot_size :: proc(state: ^Planetary_State) -> int {
	assert(state != nil, "planetary_snapshot_size: nil state")
	cell_bytes :=
		PLANET_SIM_CELL_COUNT *
		(size_of(i32) * 16 + size_of(u32) * 45 + size_of(u64) * 2 + size_of(u8) * 3 + size_of(Plate_Crust) + size_of(Plate_Boundary))
	return(
		size_of(state.orbit) +
		size_of(state.climate.surface_revision) +
		size_of(state.biogeochemistry.diagnostics) +
		size_of(state.biogeochemistry.revision) +
		tectonics_snapshot_size(&state.tectonics) +
		geomorphology_snapshot_size(&state.geomorphology) +
		size_of(state.geology.mantle_temperature_mk) +
		size_of(state.geology.core_temperature_mk) +
		size_of(state.geology.radiogenic_tw_milli) +
		size_of(state.geology.primordial_tw_milli) +
		size_of(state.volcanism.centres) +
		size_of(state.volcanism.count) +
		size_of(state.events) +
		size_of(state.diagnostics) +
		size_of(state.waves.sources) +
		size_of(state.waves.packets) +
		size_of(state.waves.source_count) +
		size_of(state.waves.packet_count) +
		size_of(state.waves.next_source_id) +
		size_of(state.waves.next_packet_id) +
		size_of(state.waves.merged_packets) +
		size_of(state.waves.dropped_packets) +
		size_of(state.waves.simulation_time_ms) +
		cell_bytes \
	)
}

planetary_snapshot_write :: proc(
	state: ^Planetary_State,
	buffer: []u8,
) -> (
	written: int,
	ok: bool,
) {
	assert(state != nil, "planetary_snapshot_write: nil state")
	if len(buffer) < planetary_snapshot_size(state) do return 0, false
	cursor := 0
	planetary_snapshot_put(buffer, &cursor, mem.ptr_to_bytes(&state.orbit))
	planetary_snapshot_put(buffer, &cursor, mem.ptr_to_bytes(&state.climate.surface_revision))
	planetary_snapshot_put(buffer, &cursor, mem.slice_to_bytes(state.climate.temperature))
	planetary_snapshot_put(buffer, &cursor, mem.slice_to_bytes(state.climate.pressure))
	planetary_snapshot_put(buffer, &cursor, mem.slice_to_bytes(state.climate.column_mass))
	planetary_snapshot_put(buffer, &cursor, mem.slice_to_bytes(state.climate.vapour))
	planetary_snapshot_put(buffer, &cursor, mem.slice_to_bytes(state.climate.cloud))
	planetary_snapshot_put(buffer, &cursor, mem.slice_to_bytes(state.climate.volcanic_aerosol))
	planetary_snapshot_put(buffer, &cursor, mem.slice_to_bytes(state.climate.precipitation))
	planetary_snapshot_put(buffer, &cursor, mem.slice_to_bytes(state.climate.wind_east))
	planetary_snapshot_put(buffer, &cursor, mem.slice_to_bytes(state.climate.wind_north))
	planetary_snapshot_put(buffer, &cursor, mem.slice_to_bytes(state.climate.soil_water))
	planetary_snapshot_put(buffer, &cursor, mem.slice_to_bytes(state.climate.snow))
	planetary_snapshot_put(buffer, &cursor, mem.slice_to_bytes(state.climate.sea_ice))
	planetary_snapshot_put(buffer, &cursor, mem.slice_to_bytes(state.climate.solar_irradiance))
	planetary_snapshot_put(buffer, &cursor, mem.slice_to_bytes(state.climate.photosynthetic_radiation))
	planetary_snapshot_put(buffer, &cursor, mem.slice_to_bytes(state.ocean.mean_depth_mm))
	planetary_snapshot_put(buffer, &cursor, mem.slice_to_bytes(state.ocean.surface_mm))
	planetary_snapshot_put(buffer, &cursor, mem.slice_to_bytes(state.ocean.transport_east))
	planetary_snapshot_put(buffer, &cursor, mem.slice_to_bytes(state.ocean.transport_north))
	planetary_snapshot_put(buffer, &cursor, mem.slice_to_bytes(state.ocean.deep_transport_east))
	planetary_snapshot_put(buffer, &cursor, mem.slice_to_bytes(state.ocean.deep_transport_north))
	planetary_snapshot_put(buffer, &cursor, mem.slice_to_bytes(state.ocean.temperature))
	for field in biogeochemistry_fields(&state.biogeochemistry) do planetary_snapshot_put(buffer, &cursor, mem.slice_to_bytes(field))
	planetary_snapshot_put(buffer, &cursor, mem.slice_to_bytes(state.biogeochemistry.surface_par))
	planetary_snapshot_put(buffer, &cursor, mem.slice_to_bytes(state.biogeochemistry.benthic_par))
	planetary_snapshot_put(buffer, &cursor, mem.slice_to_bytes(state.biogeochemistry.bottom_temperature_mk))
	planetary_snapshot_put(buffer, &cursor, mem.slice_to_bytes(state.biogeochemistry.pathway_energy))
	planetary_snapshot_put(buffer, &cursor, mem.ptr_to_bytes(&state.biogeochemistry.diagnostics))
	planetary_snapshot_put(buffer, &cursor, mem.ptr_to_bytes(&state.biogeochemistry.revision))
	tectonic_written, tectonic_ok := tectonics_snapshot_write(&state.tectonics, buffer[cursor:])
	if !tectonic_ok do return 0, false
	cursor += tectonic_written
	geomorphology_written, geomorphology_ok := geomorphology_snapshot_write(
		&state.geomorphology,
		buffer[cursor:],
	)
	if !geomorphology_ok do return 0, false
	cursor += geomorphology_written
	planetary_snapshot_put(buffer, &cursor, mem.slice_to_bytes(state.waves.wind_sea_variance))
	planetary_snapshot_put(buffer, &cursor, mem.slice_to_bytes(state.waves.wind_sea_period_ms))
	planetary_snapshot_put(buffer, &cursor, mem.slice_to_bytes(state.waves.wind_sea_direction_east))
	planetary_snapshot_put(buffer, &cursor, mem.slice_to_bytes(state.waves.wind_sea_direction_north))
	planetary_snapshot_put(buffer, &cursor, mem.slice_to_bytes(state.waves.fetch_m))
	planetary_snapshot_put(buffer, &cursor, mem.slice_to_bytes(state.waves.swell_variance))
	planetary_snapshot_put(buffer, &cursor, mem.slice_to_bytes(state.waves.swell_period_ms))
	planetary_snapshot_put(buffer, &cursor, mem.slice_to_bytes(state.waves.swell_direction_east))
	planetary_snapshot_put(buffer, &cursor, mem.slice_to_bytes(state.waves.swell_direction_north))
	planetary_snapshot_put(buffer, &cursor, mem.ptr_to_bytes(&state.waves.sources))
	planetary_snapshot_put(buffer, &cursor, mem.ptr_to_bytes(&state.waves.packets))
	planetary_snapshot_put(buffer, &cursor, mem.ptr_to_bytes(&state.waves.source_count))
	planetary_snapshot_put(buffer, &cursor, mem.ptr_to_bytes(&state.waves.packet_count))
	planetary_snapshot_put(buffer, &cursor, mem.ptr_to_bytes(&state.waves.next_source_id))
	planetary_snapshot_put(buffer, &cursor, mem.ptr_to_bytes(&state.waves.next_packet_id))
	planetary_snapshot_put(buffer, &cursor, mem.ptr_to_bytes(&state.waves.merged_packets))
	planetary_snapshot_put(buffer, &cursor, mem.ptr_to_bytes(&state.waves.dropped_packets))
	planetary_snapshot_put(buffer, &cursor, mem.ptr_to_bytes(&state.waves.simulation_time_ms))
	planetary_snapshot_put(buffer, &cursor, mem.slice_to_bytes(state.waves.height_mm))
	planetary_snapshot_put(buffer, &cursor, mem.slice_to_bytes(state.waves.period_ms))
	planetary_snapshot_put(buffer, &cursor, mem.slice_to_bytes(state.waves.direction_east))
	planetary_snapshot_put(buffer, &cursor, mem.slice_to_bytes(state.waves.direction_north))
	planetary_snapshot_put(buffer, &cursor, mem.slice_to_bytes(state.waves.breaking))
	planetary_snapshot_put(buffer, &cursor, mem.slice_to_bytes(state.waves.breaker_type))
	planetary_snapshot_put(buffer, &cursor, mem.slice_to_bytes(state.waves.runup_mm))
	planetary_snapshot_put(buffer, &cursor, mem.slice_to_bytes(state.geology.crust_age_ka))
	planetary_snapshot_put(buffer, &cursor, mem.slice_to_bytes(state.geology.crust_thickness_m))
	planetary_snapshot_put(buffer, &cursor, mem.slice_to_bytes(state.geology.permeability_nano))
	planetary_snapshot_put(buffer, &cursor, mem.slice_to_bytes(state.geology.hydration_ppm))
	planetary_snapshot_put(buffer, &cursor, mem.slice_to_bytes(state.geology.heat_flux_mw_m2))
	planetary_snapshot_put(buffer, &cursor, mem.slice_to_bytes(state.geology.plate_id))
	planetary_snapshot_put(buffer, &cursor, mem.slice_to_bytes(state.geology.crust))
	planetary_snapshot_put(buffer, &cursor, mem.slice_to_bytes(state.geology.boundary))
	planetary_snapshot_put(buffer, &cursor, mem.slice_to_bytes(state.geology.boundary_strength))
	planetary_snapshot_put(buffer, &cursor, mem.slice_to_bytes(state.geology.magma_supply))
	planetary_snapshot_put(buffer, &cursor, mem.ptr_to_bytes(&state.geology.mantle_temperature_mk))
	planetary_snapshot_put(buffer, &cursor, mem.ptr_to_bytes(&state.geology.core_temperature_mk))
	planetary_snapshot_put(buffer, &cursor, mem.ptr_to_bytes(&state.geology.radiogenic_tw_milli))
	planetary_snapshot_put(buffer, &cursor, mem.ptr_to_bytes(&state.geology.primordial_tw_milli))
	planetary_snapshot_put(buffer, &cursor, mem.ptr_to_bytes(&state.volcanism.centres))
	planetary_snapshot_put(buffer, &cursor, mem.ptr_to_bytes(&state.volcanism.count))
	planetary_snapshot_put(buffer, &cursor, mem.slice_to_bytes(state.volcanism.lava_mm))
	planetary_snapshot_put(buffer, &cursor, mem.slice_to_bytes(state.volcanism.ash))
	planetary_snapshot_put(buffer, &cursor, mem.ptr_to_bytes(&state.events))
	planetary_snapshot_put(buffer, &cursor, mem.ptr_to_bytes(&state.diagnostics))
	assert(cursor == planetary_snapshot_size(state), "planetary_snapshot_write: size mismatch")
	return cursor, true
}

planetary_snapshot_read :: proc(state: ^Planetary_State, buffer: []u8) -> bool {
	assert(state != nil, "planetary_snapshot_read: nil state")
	if len(buffer) != planetary_snapshot_size(state) do return false
	cursor := 0
	planetary_snapshot_get(buffer, &cursor, mem.ptr_to_bytes(&state.orbit))
	planetary_snapshot_get(buffer, &cursor, mem.ptr_to_bytes(&state.climate.surface_revision))
	planetary_snapshot_get(buffer, &cursor, mem.slice_to_bytes(state.climate.temperature))
	planetary_snapshot_get(buffer, &cursor, mem.slice_to_bytes(state.climate.pressure))
	planetary_snapshot_get(buffer, &cursor, mem.slice_to_bytes(state.climate.column_mass))
	planetary_snapshot_get(buffer, &cursor, mem.slice_to_bytes(state.climate.vapour))
	planetary_snapshot_get(buffer, &cursor, mem.slice_to_bytes(state.climate.cloud))
	planetary_snapshot_get(buffer, &cursor, mem.slice_to_bytes(state.climate.volcanic_aerosol))
	planetary_snapshot_get(buffer, &cursor, mem.slice_to_bytes(state.climate.precipitation))
	planetary_snapshot_get(buffer, &cursor, mem.slice_to_bytes(state.climate.wind_east))
	planetary_snapshot_get(buffer, &cursor, mem.slice_to_bytes(state.climate.wind_north))
	planetary_snapshot_get(buffer, &cursor, mem.slice_to_bytes(state.climate.soil_water))
	planetary_snapshot_get(buffer, &cursor, mem.slice_to_bytes(state.climate.snow))
	planetary_snapshot_get(buffer, &cursor, mem.slice_to_bytes(state.climate.sea_ice))
	planetary_snapshot_get(buffer, &cursor, mem.slice_to_bytes(state.climate.solar_irradiance))
	planetary_snapshot_get(buffer, &cursor, mem.slice_to_bytes(state.climate.photosynthetic_radiation))
	planetary_snapshot_get(buffer, &cursor, mem.slice_to_bytes(state.ocean.mean_depth_mm))
	planetary_snapshot_get(buffer, &cursor, mem.slice_to_bytes(state.ocean.surface_mm))
	planetary_snapshot_get(buffer, &cursor, mem.slice_to_bytes(state.ocean.transport_east))
	planetary_snapshot_get(buffer, &cursor, mem.slice_to_bytes(state.ocean.transport_north))
	planetary_snapshot_get(buffer, &cursor, mem.slice_to_bytes(state.ocean.deep_transport_east))
	planetary_snapshot_get(buffer, &cursor, mem.slice_to_bytes(state.ocean.deep_transport_north))
	planetary_snapshot_get(buffer, &cursor, mem.slice_to_bytes(state.ocean.temperature))
	for field in biogeochemistry_fields(&state.biogeochemistry) do planetary_snapshot_get(buffer, &cursor, mem.slice_to_bytes(field))
	planetary_snapshot_get(buffer, &cursor, mem.slice_to_bytes(state.biogeochemistry.surface_par))
	planetary_snapshot_get(buffer, &cursor, mem.slice_to_bytes(state.biogeochemistry.benthic_par))
	planetary_snapshot_get(buffer, &cursor, mem.slice_to_bytes(state.biogeochemistry.bottom_temperature_mk))
	planetary_snapshot_get(buffer, &cursor, mem.slice_to_bytes(state.biogeochemistry.pathway_energy))
	planetary_snapshot_get(buffer, &cursor, mem.ptr_to_bytes(&state.biogeochemistry.diagnostics))
	planetary_snapshot_get(buffer, &cursor, mem.ptr_to_bytes(&state.biogeochemistry.revision))
	tectonic_size := tectonics_snapshot_size(&state.tectonics)
	if !tectonics_snapshot_read(&state.tectonics, buffer[cursor:cursor + tectonic_size]) do return false
	cursor += tectonic_size
	geomorphology_size := geomorphology_snapshot_size(&state.geomorphology)
	geomorphology_ok := geomorphology_snapshot_read(
		&state.geomorphology,
		buffer[cursor:cursor + geomorphology_size],
	)
	if !geomorphology_ok do return false
	cursor += geomorphology_size
	planetary_snapshot_get(buffer, &cursor, mem.slice_to_bytes(state.waves.wind_sea_variance))
	planetary_snapshot_get(buffer, &cursor, mem.slice_to_bytes(state.waves.wind_sea_period_ms))
	planetary_snapshot_get(buffer, &cursor, mem.slice_to_bytes(state.waves.wind_sea_direction_east))
	planetary_snapshot_get(buffer, &cursor, mem.slice_to_bytes(state.waves.wind_sea_direction_north))
	planetary_snapshot_get(buffer, &cursor, mem.slice_to_bytes(state.waves.fetch_m))
	planetary_snapshot_get(buffer, &cursor, mem.slice_to_bytes(state.waves.swell_variance))
	planetary_snapshot_get(buffer, &cursor, mem.slice_to_bytes(state.waves.swell_period_ms))
	planetary_snapshot_get(buffer, &cursor, mem.slice_to_bytes(state.waves.swell_direction_east))
	planetary_snapshot_get(buffer, &cursor, mem.slice_to_bytes(state.waves.swell_direction_north))
	planetary_snapshot_get(buffer, &cursor, mem.ptr_to_bytes(&state.waves.sources))
	planetary_snapshot_get(buffer, &cursor, mem.ptr_to_bytes(&state.waves.packets))
	planetary_snapshot_get(buffer, &cursor, mem.ptr_to_bytes(&state.waves.source_count))
	planetary_snapshot_get(buffer, &cursor, mem.ptr_to_bytes(&state.waves.packet_count))
	planetary_snapshot_get(buffer, &cursor, mem.ptr_to_bytes(&state.waves.next_source_id))
	planetary_snapshot_get(buffer, &cursor, mem.ptr_to_bytes(&state.waves.next_packet_id))
	planetary_snapshot_get(buffer, &cursor, mem.ptr_to_bytes(&state.waves.merged_packets))
	planetary_snapshot_get(buffer, &cursor, mem.ptr_to_bytes(&state.waves.dropped_packets))
	planetary_snapshot_get(buffer, &cursor, mem.ptr_to_bytes(&state.waves.simulation_time_ms))
	planetary_snapshot_get(buffer, &cursor, mem.slice_to_bytes(state.waves.height_mm))
	planetary_snapshot_get(buffer, &cursor, mem.slice_to_bytes(state.waves.period_ms))
	planetary_snapshot_get(buffer, &cursor, mem.slice_to_bytes(state.waves.direction_east))
	planetary_snapshot_get(buffer, &cursor, mem.slice_to_bytes(state.waves.direction_north))
	planetary_snapshot_get(buffer, &cursor, mem.slice_to_bytes(state.waves.breaking))
	planetary_snapshot_get(buffer, &cursor, mem.slice_to_bytes(state.waves.breaker_type))
	planetary_snapshot_get(buffer, &cursor, mem.slice_to_bytes(state.waves.runup_mm))
	planetary_snapshot_get(buffer, &cursor, mem.slice_to_bytes(state.geology.crust_age_ka))
	planetary_snapshot_get(buffer, &cursor, mem.slice_to_bytes(state.geology.crust_thickness_m))
	planetary_snapshot_get(buffer, &cursor, mem.slice_to_bytes(state.geology.permeability_nano))
	planetary_snapshot_get(buffer, &cursor, mem.slice_to_bytes(state.geology.hydration_ppm))
	planetary_snapshot_get(buffer, &cursor, mem.slice_to_bytes(state.geology.heat_flux_mw_m2))
	planetary_snapshot_get(buffer, &cursor, mem.slice_to_bytes(state.geology.plate_id))
	planetary_snapshot_get(buffer, &cursor, mem.slice_to_bytes(state.geology.crust))
	planetary_snapshot_get(buffer, &cursor, mem.slice_to_bytes(state.geology.boundary))
	planetary_snapshot_get(buffer, &cursor, mem.slice_to_bytes(state.geology.boundary_strength))
	planetary_snapshot_get(buffer, &cursor, mem.slice_to_bytes(state.geology.magma_supply))
	planetary_snapshot_get(buffer, &cursor, mem.ptr_to_bytes(&state.geology.mantle_temperature_mk))
	planetary_snapshot_get(buffer, &cursor, mem.ptr_to_bytes(&state.geology.core_temperature_mk))
	planetary_snapshot_get(buffer, &cursor, mem.ptr_to_bytes(&state.geology.radiogenic_tw_milli))
	planetary_snapshot_get(buffer, &cursor, mem.ptr_to_bytes(&state.geology.primordial_tw_milli))
	planetary_snapshot_get(buffer, &cursor, mem.ptr_to_bytes(&state.volcanism.centres))
	planetary_snapshot_get(buffer, &cursor, mem.ptr_to_bytes(&state.volcanism.count))
	planetary_snapshot_get(buffer, &cursor, mem.slice_to_bytes(state.volcanism.lava_mm))
	planetary_snapshot_get(buffer, &cursor, mem.slice_to_bytes(state.volcanism.ash))
	planetary_snapshot_get(buffer, &cursor, mem.ptr_to_bytes(&state.events))
	planetary_snapshot_get(buffer, &cursor, mem.ptr_to_bytes(&state.diagnostics))
	assert(cursor == len(buffer), "planetary_snapshot_read: size mismatch")
	// Derived wave fields are not snapshotted; drop their cache keys so the
	// next wave step rebuilds them from the restored inputs.
	waves_invalidate_derived(&state.waves)
	planetary_mark_mutated(state)
	return true
}

planetary_snapshot_put :: proc(buffer: []u8, cursor: ^int, source: []u8) {
	assert(cursor != nil, "planetary_snapshot_put: nil cursor")
	assert(
		cursor^ >= 0 && cursor^ + len(source) <= len(buffer),
		"planetary_snapshot_put: overflow",
	)
	copy(buffer[cursor^:], source)
	cursor^ += len(source)
}

planetary_snapshot_get :: proc(buffer: []u8, cursor: ^int, target: []u8) {
	assert(cursor != nil, "planetary_snapshot_get: nil cursor")
	assert(
		cursor^ >= 0 && cursor^ + len(target) <= len(buffer),
		"planetary_snapshot_get: overflow",
	)
	copy(target, buffer[cursor^:cursor^ + len(target)])
	cursor^ += len(target)
}

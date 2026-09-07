// debug_seam.odin implements the cube-sphere side of the debug panel's
// world-model seam (see ../../forgecore/WORLDMODEL.md): mapping a picked
// surface point onto the render patch that owns it, and remeshing that patch
// on demand.
package main

import shared "../shared"
import "core:fmt"
import "core:math/linalg"

debug_panel_terrain_extension :: proc(
	value: ^Client_State,
	panel: ^Debug_Panel_Extension_Context,
	ref: Debug_Terrain_Ref,
) {
	assert(value != nil && panel != nil, "debug terrain extension: nil input")
	if !ref.valid || ref.face < 0 do return
	direction := linalg.normalize(ref.point)
	coord := shared.planet_coord_from_direction(direction)
	sample := shared.terrain_sample_at_coord(&value.world, coord)
	surface := shared.terrain_surface_state_at_coord(&value.world, coord)
	snow_amount := surface.snow_cover
	index := surface.sim_index
	planet := &value.world.planetary
	climate := &planet.climate
	ocean := &planet.ocean
	biogeochemistry := &planet.biogeochemistry
	waves := &planet.waves
	incidence := shared.orbit_solar_incidence(
		surface.latitude_microdegrees,
		planet.grid.longitude_phase[index],
		planet.orbit,
		planet.physical,
	)
	declination := shared.orbit_solar_declination_microdegrees(
		planet.orbit.orbital_phase,
		planet.physical,
	)
	flux_factor := shared.orbit_flux_factor_ppm(planet.orbit.orbital_phase, planet.physical)
	rock_weight, snow_weight := terrain_material_weights(sample.slope, snow_amount)
	mask := u8(snow_amount * 255)
	if debug_panel_extension_category(panel, .World) {
		_ = debug_panel_extension_group(panel, "CURRENT FOCUS", .Simple)
		debug_panel_extension_readout(
			panel,
			"latitude / sim cell",
			fmt.tprintf("%.2f deg / %d", f32(surface.latitude_microdegrees) / 1_000_000, index),
		)
		debug_panel_extension_readout(
			panel,
			"orbit / local phase",
			fmt.tprintf(
				"%.3f / %.3f",
				f32(planet.orbit.orbital_phase) / f32(shared.ORBIT_PHASE_SCALE),
				f32((planet.orbit.rotation_phase + planet.grid.longitude_phase[index]) % shared.ORBIT_PHASE_SCALE) / f32(shared.ORBIT_PHASE_SCALE),
			),
		)
	}
	if debug_panel_extension_category(panel, .Terrain) {
		_ = debug_panel_extension_group(panel, "CURRENT SURFACE", .Simple)
		lithosphere_debug_extension(value, panel)
		debug_panel_extension_readout(panel, "surface", fmt.tprintf("%v", surface.surface_class))
		debug_panel_extension_readout(
			panel,
			"surface temperature",
			fmt.tprintf("%.2f C", f32(surface.surface_temperature_mk) / 1_000 - 273.15),
		)
		debug_panel_extension_readout(
			panel,
			"snow cover / mask",
		fmt.tprintf("%.0f%% / %d", snow_amount * 100, mask),
	)
	debug_panel_extension_readout(
		panel,
		"rock / snow weights",
		fmt.tprintf("%.2f / %.2f", rock_weight, snow_weight),
	)
		debug_panel_extension_readout(
			panel,
			"material revisions",
			fmt.tprintf("sim %d / render %d", surface.revision, value.terrain.surface_publication.published.climate),
		)
		publication := &value.terrain.surface_publication
		habitat := shared.flora_habitat_at_cell(&value.world, index)
		ground, canopy := planet_material_flora_cover(&value.world, direction)
		debug_panel_extension_readout(panel, "potential biome", fmt.tprintf("%v", habitat.biome))
		debug_panel_extension_readout(panel, "realized ground / canopy", fmt.tprintf("%.1f%% / %.1f%%", ground * 100, canopy * 100))
		debug_panel_extension_readout(panel, "habitat moisture / temperature", fmt.tprintf("%d / %d", habitat.mean_moisture, habitat.mean_temperature))
		debug_panel_extension_readout(panel, "material publication", fmt.tprintf("generation %d / rows %d of %d / pending %v", publication.generations, publication.order_cursor, publication.order_count, publication.pending))
		debug_panel_extension_readout(panel, "material frame work", fmt.tprintf("%d rows / %d face uploads", value.terrain.last_bake_rows, value.terrain.last_upload_faces))
		geology := &planet.geology
		lithosphere := shared.lithosphere_sample(&value.world.foundation.lithosphere, shared.planet_direction(coord))
		debug_panel_extension_readout(
			panel,
			"plate pair / crust / boundary",
			fmt.tprintf(
				"%d:%d / %v:%v / %v",
				lithosphere.plate_id,
				lithosphere.neighbour_plate_id,
				lithosphere.crust,
				lithosphere.neighbour_crust,
				lithosphere.boundary,
			),
		)
		debug_panel_extension_readout(
			panel,
			"role / distance / strength",
			fmt.tprintf("%v / %.1f m / %.2f", lithosphere.role, lithosphere.boundary_distance, lithosphere.boundary_strength),
		)
		debug_panel_extension_readout(
			panel,
			"convergence / shear / relief",
			fmt.tprintf("%.2f / %.2f / %.1f m", lithosphere.convergence, lithosphere.shear, lithosphere.tectonic_relief),
		)
		tectonics := &planet.tectonics
		debug_panel_extension_readout(
			panel,
			"geological age / epoch",
			fmt.tprintf(
				"%d yr / %d",
				value.world.foundation.lithosphere.geological_age_years,
				tectonics.epoch,
			),
		)
		debug_panel_extension_readout(
			panel,
			"normal / shear speed",
			fmt.tprintf(
				"%d / %d mm/yr",
				lithosphere.normal_speed_mm_yr,
				lithosphere.shear_speed_mm_yr,
			),
		)
		debug_panel_extension_readout(
			panel,
			"strain / uplift / subsidence",
			fmt.tprintf(
				"%d / %d / %d",
				tectonics.strain_micro[index],
				tectonics.uplift_fixed[index],
				tectonics.subsidence_fixed[index],
			),
		)
		debug_panel_extension_readout(
			panel,
			"sediment / tectonic revision",
			fmt.tprintf("%d / %d", tectonics.sediment_fixed[index], tectonics.revision),
		)
		debug_panel_extension_readout(
			panel,
			"crust age / thickness / heat",
			fmt.tprintf(
				"%d ka / %d m / %d mW/m2",
				geology.crust_age_ka[index],
				geology.crust_thickness_m[index],
				geology.heat_flux_mw_m2[index],
			),
		)
	}
	if debug_panel_extension_category(panel, .Weather) {
		_ = debug_panel_extension_group(panel, "CURRENT WEATHER", .Simple)
		debug_panel_extension_readout(
			panel,
			"air temperature",
			fmt.tprintf(
				"%.2f C / %.2f K",
				f32(surface.air_temperature_mk) / 1_000 - 273.15,
				f32(surface.air_temperature_mk) / 1_000,
			),
		)
		_ = debug_panel_extension_group(panel, "ORBITAL WEATHER", .Advanced)
		debug_panel_extension_readout(
			panel,
			"sun declination / incidence",
			fmt.tprintf("%.2f deg / %.1f%%", f32(declination) / 1_000_000, f32(incidence) / 10_000),
		)
		debug_panel_extension_readout(
			panel,
			"orbital flux",
			fmt.tprintf("%.3fx", f32(flux_factor) / 1_000_000),
		)
	debug_panel_extension_readout(
		panel,
		"pressure / humidity",
		fmt.tprintf("%d Pa / %d", climate.pressure[index], climate.vapour[index]),
	)
	debug_panel_extension_readout(
		panel,
		"cloud / precipitation",
		fmt.tprintf("%d / %d", climate.cloud[index], surface.precipitation),
	)
	debug_panel_extension_readout(
		panel,
		"snow / sea ice",
		fmt.tprintf("%d / %d", surface.stored_snow, surface.sea_ice),
	)
		debug_panel_extension_readout(
			panel,
			"wind east / north",
			fmt.tprintf("%d / %d", climate.wind_east[index], climate.wind_north[index]),
		)
	}
	if debug_panel_extension_category(panel, .Water) {
		_ = debug_panel_extension_group(panel, "CURRENT WATER & WAVES", .Simple)
		debug_panel_extension_readout(
			panel,
			"ocean depth / surface",
		fmt.tprintf("%d / %d mm", ocean.mean_depth_mm[index], ocean.surface_mm[index]),
	)
	debug_panel_extension_readout(
		panel,
		"surface current east / north",
		fmt.tprintf("%d / %d", ocean.transport_east[index], ocean.transport_north[index]),
	)
	debug_panel_extension_readout(
		panel,
		"deep current east / north",
		fmt.tprintf("%d / %d", ocean.deep_transport_east[index], ocean.deep_transport_north[index]),
	)
	_ = debug_panel_extension_group(panel, "LOCAL CHEMISTRY", .Advanced)
	debug_panel_extension_readout(
		panel,
		"ocean / bottom temperature",
		fmt.tprintf(
			"%.2f / %.2f K",
			f32(ocean.temperature[index]) / 1_000,
			f32(biogeochemistry.bottom_temperature_mk[index]) / 1_000,
		),
	)
	debug_panel_extension_readout(panel, "solar / surface / benthic PAR", fmt.tprintf("%d / %d / %d", climate.solar_irradiance[index], biogeochemistry.surface_par[index], biogeochemistry.benthic_par[index]))
	debug_panel_extension_readout(panel, "salinity / oxygen / carbon", fmt.tprintf("%d / %d / %d", biogeochemistry.salinity[index], biogeochemistry.dissolved_oxygen[index], biogeochemistry.dissolved_inorganic_carbon[index]))
	debug_panel_extension_readout(panel, "sulfide / hydrogen / methane", fmt.tprintf("%d / %d / %d", biogeochemistry.hydrogen_sulfide[index], biogeochemistry.hydrogen[index], biogeochemistry.methane[index]))
	debug_panel_extension_readout(panel, "iron / nitrate / ammonium", fmt.tprintf("%d / %d / %d", biogeochemistry.ferrous_iron[index], biogeochemistry.nitrate[index], biogeochemistry.ammonium[index]))
	debug_panel_extension_readout(panel, "phosphate / organic / turbidity", fmt.tprintf("%d / %d / %d", biogeochemistry.phosphate[index], biogeochemistry.dissolved_organic_carbon[index], biogeochemistry.turbidity[index]))
	debug_panel_extension_readout(panel, "pathway energy S/M/F/H", fmt.tprintf("%d / %d / %d / %d", biogeochemistry.pathway_energy[index][0], biogeochemistry.pathway_energy[index][1], biogeochemistry.pathway_energy[index][2], biogeochemistry.pathway_energy[index][3]))
	_ = debug_panel_extension_group(panel, "CURRENT WATER & WAVES", .Simple)
	wind_sea_height := f32(shared.integer_sqrt(waves.wind_sea_variance[index]) * 4) / 1_000
	swell_height := f32(shared.integer_sqrt(waves.swell_variance[index]) * 4) / 1_000
	debug_panel_extension_readout(
		panel,
		"authoritative wind sea / swell",
		fmt.tprintf("%.3f / %.3f m", wind_sea_height, swell_height),
	)
	debug_panel_extension_readout(
		panel,
		"fetch / packets",
		fmt.tprintf("%d m / %d", waves.fetch_m[index], waves.packet_count),
	)
	debug_panel_extension_readout(
		panel,
		"authoritative wave height / period",
		fmt.tprintf("%d mm / %.2f s", waves.height_mm[index], f32(waves.period_ms[index]) / 1_000),
	)
		debug_panel_extension_readout(
			panel,
			"wave direction / break",
			fmt.tprintf(
				"%d,%d / %d",
				waves.direction_east[index],
				waves.direction_north[index],
				waves.breaking[index],
			),
		)
	}
}

// debug_terrain_locate snaps a world-space hit point to its planet cell and
// resolves the face render patch that owns it. chunk_x/chunk_y are the
// face-local patch coordinates; grid_x/grid_y the face-local cell.
debug_terrain_locate :: proc(value: ^Client_State, point: [3]f32) -> (Debug_Terrain_Ref, bool) {
	assert(value != nil, "debug_terrain_locate: nil state")
	if !value.terrain.ready do return {}, false
	length := linalg.length(point)
	if length <= 0.001 do return {}, false
	direction := point / length
	coord := shared.planet_coord_from_direction(direction)
	if !shared.planet_coord_valid(coord) do return {}, false
	sample := shared.terrain_sample_at_direction(&value.world, direction)
	height := shared.terrain_height_at_direction(&value.world, direction)
	patch_u := clamp(
		int(coord.u) / shared.PLANET_PATCH_CELLS,
		0,
		shared.PLANET_PATCHES_PER_FACE - 1,
	)
	patch_v := clamp(
		int(coord.v) / shared.PLANET_PATCH_CELLS,
		0,
		shared.PLANET_PATCHES_PER_FACE - 1,
	)
	// The patch's world box: centered on the patch-centre surface point,
	// sized by the patch's cell span. Coarse (the patch is curved) but all
	// the scope outline needs.
	center_coord := shared.Planet_Coord {
		coord.face,
		i32(patch_u * shared.PLANET_PATCH_CELLS + shared.PLANET_PATCH_CELLS / 2),
		i32(patch_v * shared.PLANET_PATCH_CELLS + shared.PLANET_PATCH_CELLS / 2),
	}
	center_direction := shared.planet_direction(center_coord)
	center_height := shared.terrain_height_at_coord(&value.world, center_coord)
	span := f32(shared.PLANET_PATCH_CELLS) * shared.GRID_CELL_SIZE
	ref := Debug_Terrain_Ref {
		face           = i32(coord.face),
		chunk_x        = i32(patch_u),
		chunk_y        = i32(patch_v),
		chunk_index    = _planet_patch_index_for(coord),
		grid_x         = coord.u,
		grid_y         = coord.v,
		height         = height,
		biome          = sample.primary_biome,
		point          = point,
		surface_normal = direction,
		bounds_center  = shared.planet_position(center_direction, center_height),
		bounds_size    = {span, span, span * 0.5},
		valid          = true,
	}
	return ref, true
}

// debug_terrain_remesh marks the referenced render patch dirty; the normal
// terrain_update path rebuilds it on the next frame.
debug_terrain_remesh :: proc(value: ^Client_State, ref: Debug_Terrain_Ref) {
	assert(value != nil, "debug_terrain_remesh: nil state")
	if !ref.valid || !value.terrain.ready do return
	if ref.chunk_index < 0 || ref.chunk_index >= PLANET_RENDER_PATCH_COUNT do return
	value.terrain.dirty[ref.chunk_index] = true
}

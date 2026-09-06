package shared

import "core:testing"

biogeochemistry_transport_field_scalar_reference :: proc(
	planet: ^Planetary_State,
	field: []u32,
	scratch: []i64,
) -> i64 {
	for &value in scratch do value = 0
	before := biogeochemistry_field_total(field)
	for index in 0 ..< PLANET_SIM_CELL_COUNT {
		if planet.ocean.mean_depth_mm[index] == 0 do continue
		for edge_index in 0 ..< PLANET_SIM_EDGE_COUNT {
			neighbour := int(planet.grid.neighbours[index][edge_index])
			if neighbour <= index || planet.ocean.mean_depth_mm[neighbour] == 0 do continue
			east, north := ocean_column_transport(&planet.ocean, index)
			flow :=
				(east * i64(planet.grid.edge_east[index][edge_index]) +
					north * i64(planet.grid.edge_north[index][edge_index])) /
				i64(PLANET_VECTOR_SCALE)
			transfer := (i64(field[index]) - i64(field[neighbour])) / 1_024
			if flow > 0 {
				transfer += min(
					i64(field[index]) / 256,
					flow * i64(field[index]) / i64(OCEAN_MAX_TRANSPORT) / 256,
				)
			} else if flow < 0 {
				transfer -= min(
					i64(field[neighbour]) / 256,
					-flow * i64(field[neighbour]) / i64(OCEAN_MAX_TRANSPORT) / 256,
				)
			}
			transfer = clamp(transfer, -i64(field[neighbour]) / 64, i64(field[index]) / 64)
			scratch[index] -= transfer
			scratch[neighbour] += transfer
		}
	}
	for index in 0 ..< PLANET_SIM_CELL_COUNT {
		field[index] = planet_saturating_u32(
			i64(field[index]) + scratch[index],
			BIOGEO_MAX_CONCENTRATION,
		)
	}
	after := biogeochemistry_field_total(field)
	return i64(after) - i64(before)
}

biogeochemistry_transport_step_scalar_reference :: proc(planet: ^Planetary_State) {
	residual: i64
	fields := biogeochemistry_fields(&planet.biogeochemistry)
	for field in fields {
		residual += biogeochemistry_transport_field_scalar_reference(
			planet,
			field,
			planet.biogeochemistry.transport_scratch[0],
		)
	}
	planet.biogeochemistry.diagnostics.transport_residual += residual
	planet.biogeochemistry.revision += 1
}

@(test)
biogeochemistry_diffusion_conserves_closed_field :: proc(t: ^testing.T) {
	world := new(World)
	defer free(world)
	testing.expect(t, world_init(world))
	defer world_deinit(world)
	field := world.planetary.biogeochemistry.phosphate
	for &value in field do value = 0
	wet := -1
	for depth, index in world.planetary.ocean.mean_depth_mm {
		if depth > 0 {
			wet = index
			break
		}
	}
	testing.expect(t, wet >= 0)
	field[wet] = 1_000_000
	before := biogeochemistry_field_total(field)
	residual := biogeochemistry_transport_fields(&world.planetary)
	after := biogeochemistry_field_total(field)
	testing.expect_value(t, residual, i64(0))
	testing.expect_value(t, after, before)
}

@(test)
biogeochemistry_fused_transport_matches_scalar_reference :: proc(t: ^testing.T) {
	fused := new(World)
	scalar := new(World)
	defer free(fused)
	defer free(scalar)
	testing.expect(t, world_init_seed(fused, TERRAIN_SEED))
	defer world_deinit(fused)
	testing.expect(t, world_init_seed(scalar, TERRAIN_SEED))
	defer world_deinit(scalar)
	for index in 0 ..< PLANET_SIM_CELL_COUNT {
		fused.planetary.ocean.transport_east[index] = i32((index % 257) - 128) * 1_000
		fused.planetary.ocean.transport_north[index] = i32((index % 193) - 96) * 1_000
		scalar.planetary.ocean.transport_east[index] = fused.planetary.ocean.transport_east[index]
		scalar.planetary.ocean.transport_north[index] =
			fused.planetary.ocean.transport_north[index]
	}
	biogeochemistry_transport_step(&fused.planetary)
	biogeochemistry_transport_step_scalar_reference(&scalar.planetary)
	fused_fields := biogeochemistry_fields(&fused.planetary.biogeochemistry)
	scalar_fields := biogeochemistry_fields(&scalar.planetary.biogeochemistry)
	for field, field_index in fused_fields {
		for value, index in field {
			testing.expect_value(t, value, scalar_fields[field_index][index])
		}
	}
	testing.expect_value(
		t,
		fused.planetary.biogeochemistry.diagnostics.transport_residual,
		scalar.planetary.biogeochemistry.diagnostics.transport_residual,
	)
}

@(test)
biogeochemistry_parallel_transport_matches_scalar_at_bounds :: proc(t: ^testing.T) {
	parallel := new(World)
	scalar := new(World)
	defer free(parallel)
	defer free(scalar)
	testing.expect(t, world_init_seed(parallel, TERRAIN_SEED))
	defer world_deinit(parallel)
	testing.expect(t, world_init_seed(scalar, TERRAIN_SEED))
	defer world_deinit(scalar)
	parallel_fields := biogeochemistry_fields(&parallel.planetary.biogeochemistry)
	scalar_fields := biogeochemistry_fields(&scalar.planetary.biogeochemistry)
	for field, field_index in parallel_fields {
		for &value, index in field {
			value = BIOGEO_MAX_CONCENTRATION if (index + field_index) % 2 == 0 else 0
			scalar_fields[field_index][index] = value
		}
	}
	biogeochemistry_transport_step(&parallel.planetary)
	biogeochemistry_transport_step_scalar_reference(&scalar.planetary)
	for field, field_index in parallel_fields {
		for value, index in field {
			testing.expect_value(t, value, scalar_fields[field_index][index])
		}
	}
	testing.expect_value(
		t,
		parallel.planetary.biogeochemistry.diagnostics.transport_residual,
		scalar.planetary.biogeochemistry.diagnostics.transport_residual,
	)
}

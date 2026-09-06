package shared

BIOGEO_TRANSPORT_FIELDS :: 12

biogeochemistry_cell_volume :: proc(planet: ^Planetary_State, index: int) -> u64 {
	assert(
		planet != nil && index >= 0 && index < PLANET_SIM_CELL_COUNT,
		"biogeochemistry_cell_volume: invalid input",
	)
	return planet.grid.cell_area_m2[index] * u64(planet.ocean.mean_depth_mm[index]) / 1_000
}

biogeochemistry_field_total :: proc(field: []u32) -> u64 {
	total: u64
	for value in field do total += u64(value)
	return total
}

biogeochemistry_transport_flow_prepare :: proc(planet: ^Planetary_State) {
	biogeochemistry_transport_flow_range(planet, 0, len(planet.grid.canonical_edges))
}

biogeochemistry_transport_flow_range :: proc(planet: ^Planetary_State, start, end: int) {
	for edge, offset in planet.grid.canonical_edges[start:end] {
		edge_index := start + offset
		index := int(edge.index)
		neighbour := int(edge.neighbour)
		if planet.ocean.mean_depth_mm[index] == 0 || planet.ocean.mean_depth_mm[neighbour] == 0 {
			planet.biogeochemistry.transport_flow[edge_index] = 0
			continue
		}
		east, north := ocean_column_transport(&planet.ocean, index)
		planet.biogeochemistry.transport_flow[edge_index] =
			(east * i64(edge.edge_east) + north * i64(edge.edge_north)) / i64(PLANET_VECTOR_SCALE)
	}
}

biogeochemistry_transport_field_cached :: proc(
	planet: ^Planetary_State,
	field: []u32,
	scratch: []i64,
) -> (
	u64,
	u64,
) {
	before: u64
	for index in 0 ..< PLANET_SIM_CELL_COUNT {
		scratch[index] = 0
		before += u64(field[index])
	}
	for edge, edge_index in planet.grid.canonical_edges {
		index := int(edge.index)
		neighbour := int(edge.neighbour)
		if planet.ocean.mean_depth_mm[index] == 0 || planet.ocean.mean_depth_mm[neighbour] == 0 do continue
		flow := planet.biogeochemistry.transport_flow[edge_index]
		transfer := biogeochemistry_transport_edge_transfer(field, index, neighbour, flow)
		scratch[index] -= transfer
		scratch[neighbour] += transfer
	}
	after: u64
	for index in 0 ..< PLANET_SIM_CELL_COUNT {
		field[index] = planet_saturating_u32(
			i64(field[index]) + scratch[index],
			BIOGEO_MAX_CONCENTRATION,
		)
		after += u64(field[index])
	}
	return before, after
}

// biogeochemistry_transport_edge_transfer is the per-edge, per-field
// transfer; identical for the scalar and fused traversals.
biogeochemistry_transport_edge_transfer :: proc(field: []u32, index, neighbour: int, flow: i64) -> i64 {
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
	return clamp(transfer, -i64(field[neighbour]) / 64, i64(field[index]) / 64)
}

// biogeochemistry_transport_fields_fused moves a worker's fields with one
// canonical-edge traversal instead of one per field: the edge, wet test and
// flow are loaded once and every field's transfer (unchanged arithmetic)
// lands in that field's own scratch. Fields never read each other, so the
// interleaving cannot change a result.
biogeochemistry_transport_fields_fused :: proc(
	planet: ^Planetary_State,
	fields: [][]u32,
	scratches: [][]i64,
	before, after: []u64,
) {
	assert(len(fields) == len(scratches) && len(fields) == len(before) && len(fields) == len(after), "biogeochemistry_transport_fields_fused: lengths")
	for field, field_index in fields {
		total: u64
		scratch := scratches[field_index]
		for index in 0 ..< PLANET_SIM_CELL_COUNT {
			scratch[index] = 0
			total += u64(field[index])
		}
		before[field_index] = total
	}
	for edge, edge_index in planet.grid.canonical_edges {
		index := int(edge.index)
		neighbour := int(edge.neighbour)
		if planet.ocean.mean_depth_mm[index] == 0 || planet.ocean.mean_depth_mm[neighbour] == 0 do continue
		flow := planet.biogeochemistry.transport_flow[edge_index]
		for field, field_index in fields {
			transfer := biogeochemistry_transport_edge_transfer(field, index, neighbour, flow)
			scratches[field_index][index] -= transfer
			scratches[field_index][neighbour] += transfer
		}
	}
	for field, field_index in fields {
		total: u64
		scratch := scratches[field_index]
		for index in 0 ..< PLANET_SIM_CELL_COUNT {
			field[index] = planet_saturating_u32(
				i64(field[index]) + scratch[index],
				BIOGEO_MAX_CONCENTRATION,
			)
			total += u64(field[index])
		}
		after[field_index] = total
	}
}

Biogeochemistry_Transport_Job :: struct {
	planet: ^Planetary_State,
	fields: [BIOGEO_TRANSPORT_FIELDS][]u32,
	before: [BIOGEO_TRANSPORT_FIELDS]u64,
	after:  [BIOGEO_TRANSPORT_FIELDS]u64,
}

// Phase 1 splits the flow preparation over canonical edges; phase 2 gives
// each worker a contiguous field range (separate storage, separate scratch)
// moved with one fused traversal.
biogeochemistry_transport_job_run :: proc(data: rawptr, worker, workers: int, team: ^Planet_Workers) {
	job := (^Biogeochemistry_Transport_Job)(data)
	edge_start, edge_end := planet_worker_range(worker, workers, len(job.planet.grid.canonical_edges))
	biogeochemistry_transport_flow_range(job.planet, edge_start, edge_end)
	planet_workers_sync(team)
	field_start, field_end := planet_worker_range(worker, workers, BIOGEO_TRANSPORT_FIELDS)
	biogeochemistry_transport_fields_fused(
		job.planet,
		job.fields[field_start:field_end],
		job.planet.biogeochemistry.transport_scratch[field_start:field_end],
		job.before[field_start:field_end],
		job.after[field_start:field_end],
	)
}

biogeochemistry_transport_fields :: proc(planet: ^Planetary_State) -> i64 {
	assert(planet != nil, "biogeochemistry_transport_fields: nil planet")
	job := Biogeochemistry_Transport_Job {
		planet = planet,
		fields = biogeochemistry_fields(&planet.biogeochemistry),
	}
	planet_workers_run(planet.workers, biogeochemistry_transport_job_run, &job)
	residual: i64
	for field_index in 0 ..< BIOGEO_TRANSPORT_FIELDS {
		residual += i64(job.after[field_index]) - i64(job.before[field_index])
	}
	return residual
}

biogeochemistry_transport_step :: proc(planet: ^Planetary_State) {
	assert(planet != nil, "biogeochemistry_transport_step: nil planet")
	residual := biogeochemistry_transport_fields(planet)
	planet.biogeochemistry.diagnostics.transport_residual += residual
	planet.biogeochemistry.revision += 1
}

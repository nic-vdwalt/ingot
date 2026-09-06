package shared

tectonic_material_resolve_interfaces :: proc(state: ^Tectonic_State, grid: ^Planet_Sim_Grid, years: u32) {
	if years == 0 do return
	for &cell, index in state.material {
		total: Tectonic_Material
		for material in cell do tectonic_material_add(&total, material)
		area := f64(grid.cell_area_m2[index])
		owner := int(state.plate_id[index])
		if state.boundary[index] == .Ridge && total.area_m2 < area {
			opened := area - total.area_m2
			if state.continental_fraction[index] < 0.5 {
				created := opened * 7_000
				cell[owner].oceanic_volume_m3 += created
				cell[owner].area_m2 += opened
				state.created_volume_m3 += created
			} else {
				cell[owner].area_m2 += opened
			}
		} else if total.area_m2 > area {
			excess := total.area_m2 - area
			if state.role[index] == .Subducting {
				fraction := min(excess / max(total.area_m2, f64(1)), f64(0.2))
				for &material in cell {
					ocean_fraction := material.oceanic_volume_m3 / max(tectonic_material_volume(material), f64(1))
					removed_volume := material.oceanic_volume_m3 * fraction
					material.oceanic_volume_m3 -= removed_volume
					material.age_volume_years_m3 *= 1 - fraction * ocean_fraction
					material.area_m2 *= 1 - fraction * ocean_fraction
					state.recycled_volume_m3 += removed_volume
				}
			} else if state.role[index] == .Colliding {
				for &material in cell do material.area_m2 *= area / total.area_m2
			}
		}
	}
	tectonic_material_refresh(state)
}

tectonic_boundary_graph_rebuild :: proc(state: ^Tectonic_State, lithosphere: ^Lithosphere, grid: ^Planet_Sim_Grid) {
	for index in 0 ..< PLANET_SIM_CELL_COUNT {
		previous_boundary := state.boundary[index]
		previous_role := state.role[index]
		state.boundary[index] = .Intraplate
		state.role[index] = .Interior
		state.boundary_strength[index] = 0
		owner := int(state.plate_id[index])
		best := Lithosphere_Sample{}
		for neighbour_index in grid.neighbours[index] {
			other := int(state.plate_id[neighbour_index])
			if owner == other do continue
			plate, neighbour := lithosphere.plates[owner], lithosphere.plates[other]
			plate.centre = grid.directions[index]
			neighbour.centre = grid.directions[neighbour_index]
			plate.crust = state.crust[index]
			neighbour.crust = state.crust[neighbour_index]
			plate.base_crust_age_ka = state.crust_age_ka[index]
			neighbour.base_crust_age_ka = state.crust_age_ka[neighbour_index]
			sample := Lithosphere_Sample{plate_id = u8(owner), neighbour_plate_id = u8(other), crust = plate.crust, neighbour_crust = neighbour.crust, boundary_strength = 1}
			_lithosphere_classify(&sample, plate, neighbour, grid.directions[index])
			if abs(sample.normal_speed_mm_yr) + i32(sample.shear_speed_mm_yr) >= abs(best.normal_speed_mm_yr) + i32(best.shear_speed_mm_yr) do best = sample
		}
		if previous_boundary == .Subduction && best.boundary == .Subduction && state.crust[index] == .Oceanic && best.neighbour_crust == .Oceanic {
			if previous_role == .Subducting || previous_role == .Overriding do best.role = previous_role
		}
		state.boundary[index] = best.boundary
		state.role[index] = best.role
		state.boundary_strength[index] = _terrain_unit_to_u8(best.boundary_strength)
		state.normal_speed_mm_yr[index] = best.normal_speed_mm_yr
		state.shear_speed_mm_yr[index] = best.shear_speed_mm_yr
	}
}

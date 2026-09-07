package shared

import "core:math"

Tectonic_Material :: struct {
	continental_volume_m3: f64,
	oceanic_volume_m3: f64,
	age_volume_years_m3: f64,
	area_m2: f64,
}

tectonic_material_volume :: proc(material: Tectonic_Material) -> f64 {
	return material.continental_volume_m3 + material.oceanic_volume_m3
}

tectonic_material_scaled :: proc(material: Tectonic_Material, fraction: f64) -> Tectonic_Material {
	return {material.continental_volume_m3 * fraction, material.oceanic_volume_m3 * fraction, material.age_volume_years_m3 * fraction, material.area_m2 * fraction}
}

tectonic_material_add :: proc(target: ^Tectonic_Material, source: Tectonic_Material) {
	target.continental_volume_m3 += source.continental_volume_m3
	target.oceanic_volume_m3 += source.oceanic_volume_m3
	target.age_volume_years_m3 += source.age_volume_years_m3
	target.area_m2 += source.area_m2
}

tectonic_material_remap :: proc(state: ^Tectonic_State, lithosphere: ^Lithosphere, grid: ^Planet_Sim_Grid, years: u32) {
	if years == 0 do return
	maximum_speed := f64(0)
	for plate in lithosphere.plates do maximum_speed = max(maximum_speed, f64(abs(plate.speed_mm_yr)) / 1_000)
	minimum_span := f64(max(u32))
	for distances in grid.edge_length_m {
		for distance in distances do minimum_span = min(minimum_span, f64(distance))
	}
	steps := max(1, int(math.ceil(maximum_speed * f64(years) / (minimum_span * 0.2))))
	interval := f64(years) / f64(steps)
	for _ in 0 ..< steps {
		copy(state.material_scratch, state.material)
		for edge in grid.canonical_edges {
			first, second := int(edge.index), int(edge.neighbour)
			first_direction := grid.directions[first]
			second_direction := grid.directions[second]
			midpoint := _planet_normalize(first_direction + second_direction)
			tangent := _planet_normalize(second_direction - first_direction)
			interface_length := f64(0)
			for side in 0 ..< PLANET_SIM_EDGE_COUNT {
				if grid.neighbours[first][side] == u32(second) {
					interface_length = f64(grid.interface_length_m[first][side])
					break
				}
			}
			for plate, plate_index in lithosphere.plates {
				velocity := lithosphere_plate_velocity_mm_yr(plate, midpoint)
				speed := f64(_lithosphere_dot(velocity, tangent)) / 1_000
				source, destination := first, second
				if speed < 0 do source, destination = second, first
				fraction := abs(speed) * interval * interface_length / f64(grid.cell_area_m2[source])
				assert(fraction <= 0.25, "tectonic material CFL")
				transfer := tectonic_material_scaled(state.material[source][plate_index], fraction)
				tectonic_material_add(&state.material_scratch[source][plate_index], tectonic_material_scaled(transfer, -1))
				tectonic_material_add(&state.material_scratch[destination][plate_index], transfer)
			}
		}
		copy(state.material, state.material_scratch)
	}
	for &cell in state.material {
		for &material in cell {
			material.age_volume_years_m3 += tectonic_material_volume(material) * f64(years)
		}
	}
	tectonic_material_refresh(state)
}

tectonic_material_refresh :: proc(state: ^Tectonic_State) {
	for cell, index in state.material {
		total: Tectonic_Material
		owner := 0
		for material, plate in cell {
			tectonic_material_add(&total, material)
			if material.area_m2 > cell[owner].area_m2 do owner = plate
		}
		volume := tectonic_material_volume(total)
		state.plate_id[index] = u8(owner)
		state.continental_fraction[index] = total.continental_volume_m3 / max(volume, f64(1))
		state.crust[index] = .Continental if state.continental_fraction[index] >= 0.5 else .Oceanic
		state.crust_thickness_m[index] = u32(clamp(volume / max(total.area_m2, f64(1)), f64(0), f64(100_000)))
		state.crust_age_ka[index] = u32(clamp(total.age_volume_years_m3 / max(volume, f64(1)) / 1_000, f64(0), f64(max(u32))))
	}
}

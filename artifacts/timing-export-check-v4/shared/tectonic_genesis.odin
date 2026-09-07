package shared

import "core:math"

TECTONIC_GENESIS_VERSION :: u32(1)
TECTONIC_CONTINENT_COUNT :: 7

Tectonic_Genesis_Config :: struct {
	version: u32,
	ocean_fraction: f64,
	continent_radius: f32,
	margin_width: f32,
	metres_per_height_unit: f64,
}

tectonic_genesis_earthlike :: proc() -> Tectonic_Genesis_Config {
	return {TECTONIC_GENESIS_VERSION, 0.71, 0.52, 0.055, 250}
}

tectonic_genesis_generate :: proc(lithosphere: ^Lithosphere) {
	lithosphere.genesis_config = tectonic_genesis_earthlike()
	for &centre, index in lithosphere.continental_centres {
		centre = _lithosphere_hash_direction(lithosphere.seed ~ 0x9e3779b97f4a7c15, u64(index))
	}
}

tectonic_genesis_continents :: proc(lithosphere: ^Lithosphere, radial: [3]f32) -> f32 {
	config := lithosphere.genesis_config
	if config.margin_width <= 0 do return 0
	closest := f32(-1)
	for centre in lithosphere.continental_centres {
		closest = max(closest, _lithosphere_dot(radial, centre))
	}
	warp := 0.045 * math.sin(radial.x * 9 + radial.z * 5) * math.sin(radial.y * 7 - radial.z * 3)
	distance := math.acos(clamp(closest, f32(-1), f32(1))) + warp
	fraction := clamp((config.continent_radius + config.margin_width - distance) / (2 * config.margin_width), f32(0), f32(1))
	return fraction * fraction * (3 - 2 * fraction)
}

planet_genesis_sea_level_solve :: proc(field: ^Planet_Foundation) {
	histogram := make([]f64, 65_536, context.temp_allocator)
	total := f64(0)
	for index in 0 ..< PLANET_SIM_CELL_COUNT {
		coord := planet_sim_coord_for_index(index)
		height := field.base_height[planet_index(planet_sim_terrain_coord(coord))]
		weight := planet_sim_cell_solid_angle(coord)
		histogram[int(height) + 32_768] += weight
		total += weight
	}
	target := total * field.lithosphere.genesis_config.ocean_fraction
	accumulated := f64(0)
	for weight, index in histogram {
		accumulated += weight
		if accumulated >= target {
			field.sea_level = i16(index - 32_768)
			break
		}
	}
}

tectonic_genesis_ocean_age :: proc(sample: Lithosphere_Sample) -> u32 {
	if sample.crust == .Continental do return 1_500_000
	return u32(clamp(sample.boundary_distance * 750, f32(1), f32(180_000)))
}

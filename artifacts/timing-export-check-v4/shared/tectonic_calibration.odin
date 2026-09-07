package shared

import "core:math"

TECTONIC_MODEL_VERSION :: u32(1)

Tectonic_Model_Config :: struct {
	version: u32,
	radius_m: f64,
	metres_per_height_unit: f64,
	continental_density_kg_m3: f64,
	oceanic_density_kg_m3: f64,
	mantle_density_kg_m3: f64,
	sediment_density_kg_m3: f64,
	sediment_porosity: f64,
	transport_cfl: f64,
	polarity_hysteresis_kg_m3: f64,
	polarity_dwell_years: f64,
	boundary_width_m: f64,
	erosion_rate_m_yr: f64,
}

tectonic_model_earthlike :: proc() -> Tectonic_Model_Config {
	return {TECTONIC_MODEL_VERSION, 6_371_000, 250, 2_800, 2_900, 3_300, 2_650, 0.35, 0.45, 10, 100_000, 100_000, 0.0001}
}

tectonic_model_valid :: proc(config: Tectonic_Model_Config) -> bool {
	if config.version != TECTONIC_MODEL_VERSION do return false
	values := [?]f64{config.radius_m, config.metres_per_height_unit, config.continental_density_kg_m3, config.oceanic_density_kg_m3, config.mantle_density_kg_m3, config.sediment_density_kg_m3, config.sediment_porosity, config.transport_cfl, config.polarity_hysteresis_kg_m3, config.polarity_dwell_years, config.boundary_width_m, config.erosion_rate_m_yr}
	for value in values {
		if math.is_nan(value) || math.is_inf(value) do return false
	}
	return config.radius_m >= 1_000 && config.radius_m <= 100_000_000 &&
		config.metres_per_height_unit > 0 &&
		config.continental_density_kg_m3 > 0 && config.oceanic_density_kg_m3 > 0 &&
		config.mantle_density_kg_m3 > max(config.continental_density_kg_m3, config.oceanic_density_kg_m3) &&
		config.sediment_density_kg_m3 > 0 &&
		config.sediment_porosity >= 0 && config.sediment_porosity < 1 &&
		config.transport_cfl > 0 && config.transport_cfl <= 0.45 &&
		config.polarity_hysteresis_kg_m3 >= 0 && config.polarity_dwell_years >= 0 &&
		config.boundary_width_m > 0 && config.boundary_width_m <= config.radius_m &&
		config.erosion_rate_m_yr >= 0
}

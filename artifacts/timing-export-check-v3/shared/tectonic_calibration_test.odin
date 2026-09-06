package shared

import "core:testing"


@(test)
tectonic_model_rejects_invalid_parameters :: proc(t: ^testing.T) {
	config := tectonic_model_earthlike()
	testing.expect(t, tectonic_model_valid(config))
	invalid := config
	invalid.radius_m = transmute(f64)u64(0x7ff0000000000000)
	testing.expect(t, !tectonic_model_valid(invalid))
	invalid = config
	invalid.sediment_porosity = 1
	testing.expect(t, !tectonic_model_valid(invalid))
	invalid = config
	invalid.transport_cfl = 0.5
	testing.expect(t, !tectonic_model_valid(invalid))
	invalid = config
	invalid.mantle_density_kg_m3 = 1
	testing.expect(t, !tectonic_model_valid(invalid))
	invalid = config
	invalid.erosion_rate_m_yr = -1
	testing.expect(t, !tectonic_model_valid(invalid))
}

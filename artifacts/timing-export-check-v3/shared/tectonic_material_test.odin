package shared

import "core:testing"

@(test)
tectonic_material_transport_conserves_crust :: proc(t: ^testing.T) {
	world := new(World)
	defer free(world)
	testing.expect(t, world_init_seed(world, 707))
	defer world_deinit(world)
	state := &world.planetary.tectonics
	before := f64(0)
	for cell in state.material {
		for material in cell do before += tectonic_material_volume(material)
	}
	for _ in 0 ..< 10 do tectonic_material_remap(state, &world.foundation.lithosphere, &world.planetary.grid, 25_000)
	after := f64(0)
	for cell in state.material {
		for material in cell {
			testing.expect(t, material.continental_volume_m3 >= 0 && material.oceanic_volume_m3 >= 0)
			after += tectonic_material_volume(material)
		}
	}
	testing.expect(t, abs(after - before) / before < 0.000001)
}

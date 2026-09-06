#+build !js
package procgen

import "core:testing"

_feature_test_config :: proc(seed: u64) -> Feature_Placement_Config {
	return {
		seed = seed,
		salt = 0x5255_494E,
		minimum_cell = {-64, -64},
		maximum_cell = {63, 63},
		cluster_cells = 12,
		chance = 2800,
		cell_world_size = 2,
		jitter = 0.7,
		minimum_separation = 18,
		scale_minimum = 0.85,
		scale_maximum = 1.15,
		output_limit = 32,
	}
}

@(test)
feature_placements_are_deterministic :: proc(t: ^testing.T) {
	first, second: [32]Feature_Placement
	config := _feature_test_config(92741)
	first_count, first_ok := feature_placement_generate(config, first[:])
	second_count, second_ok := feature_placement_generate(config, second[:])
	testing.expect(t, first_ok && second_ok)
	testing.expect_value(t, first_count, second_count)
	for placement, index in first[:first_count] do testing.expect_value(t, placement, second[index])
}

@(test)
feature_placements_respect_bounds_and_spacing :: proc(t: ^testing.T) {
	placements: [32]Feature_Placement
	config := _feature_test_config(117)
	count, ok := feature_placement_generate(config, placements[:])
	testing.expect(t, ok)
	testing.expect(t, count > 0 && count <= int(config.output_limit))
	for placement, index in placements[:count] {
		testing.expect(t, placement.cell.x >= config.minimum_cell.x)
		testing.expect(t, placement.cell.x <= config.maximum_cell.x)
		testing.expect(t, placement.cell.y >= config.minimum_cell.y)
		testing.expect(t, placement.cell.y <= config.maximum_cell.y)
		testing.expect(t, placement.scale >= config.scale_minimum)
		testing.expect(t, placement.scale <= config.scale_maximum)
		for other in placements[:index] {
			delta_x := placement.position.x - other.position.x
			delta_y := placement.position.y - other.position.y
			testing.expect(
				t,
				delta_x * delta_x + delta_y * delta_y >=
				config.minimum_separation * config.minimum_separation,
			)
		}
	}
}

@(test)
feature_placement_chance_and_capacity_are_bounded :: proc(t: ^testing.T) {
	placements: [4]Feature_Placement
	config := _feature_test_config(88)
	config.chance = FEATURE_CHANCE_SCALE
	config.output_limit = 4
	count, ok := feature_placement_generate(config, placements[:])
	testing.expect(t, ok)
	testing.expect_value(t, count, 4)
	config.chance = 0
	count, ok = feature_placement_generate(config, placements[:])
	testing.expect(t, ok)
	testing.expect_value(t, count, 0)
}

@(test)
feature_placement_validation_rejects_invalid_configs :: proc(t: ^testing.T) {
	config := _feature_test_config(1)
	testing.expect(t, feature_placement_config_validate(config, 32))
	config.cluster_cells = 0
	testing.expect(t, !feature_placement_config_validate(config, 32))
	config = _feature_test_config(1)
	config.output_limit = 33
	testing.expect(t, !feature_placement_config_validate(config, 32))
	config = _feature_test_config(1)
	config.jitter = 1.1
	testing.expect(t, !feature_placement_config_validate(config, 32))
}

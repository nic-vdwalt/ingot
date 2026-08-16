package procgen

import "core:math"

FEATURE_CHANCE_SCALE :: u32(10000)
FEATURE_PLACEMENT_LIMIT :: 256

Feature_Placement_Config :: struct {
	seed:               u64,
	salt:               u64,
	minimum_cell:       [2]i32,
	maximum_cell:       [2]i32,
	cluster_cells:      i32,
	chance:             u32,
	cell_world_size:    f32,
	jitter:             f32,
	minimum_separation: f32,
	scale_minimum:      f32,
	scale_maximum:      f32,
	output_limit:       u16,
}

Feature_Placement :: struct {
	key:      u64,
	cell:     [2]i32,
	position: [2]f32,
	yaw:      f32,
	scale:    f32,
}

feature_placement_generate :: proc(
	config: Feature_Placement_Config,
	output: []Feature_Placement,
) -> (
	count: int,
	ok: bool,
) {
	assert(len(output) <= FEATURE_PLACEMENT_LIMIT, "feature_placement_generate: output too large")
	if !feature_placement_config_validate(config, len(output)) do return 0, false
	cluster_min_x := _feature_floor_div(config.minimum_cell.x, config.cluster_cells)
	cluster_min_y := _feature_floor_div(config.minimum_cell.y, config.cluster_cells)
	cluster_max_x := _feature_floor_div(config.maximum_cell.x, config.cluster_cells)
	cluster_max_y := _feature_floor_div(config.maximum_cell.y, config.cluster_cells)
	for cluster_y in cluster_min_y ..= cluster_max_y {
		for cluster_x in cluster_min_x ..= cluster_max_x {
			if count >= int(config.output_limit) do return count, true
			key := feature_placement_hash(config.seed, config.salt, cluster_x, cluster_y)
			if u32(key % u64(FEATURE_CHANCE_SCALE)) >= config.chance do continue
			cell_x :=
				cluster_x * config.cluster_cells + i32((key >> 16) % u64(config.cluster_cells))
			cell_y :=
				cluster_y * config.cluster_cells + i32((key >> 24) % u64(config.cluster_cells))
			if cell_x < config.minimum_cell.x || cell_x > config.maximum_cell.x do continue
			if cell_y < config.minimum_cell.y || cell_y > config.maximum_cell.y do continue
			unit_x := f32((key >> 32) & 0xFF) / 255
			unit_y := f32((key >> 40) & 0xFF) / 255
			jitter_x := (unit_x - 0.5) * config.jitter
			jitter_y := (unit_y - 0.5) * config.jitter
			position := [2]f32 {
				(f32(cell_x) + jitter_x) * config.cell_world_size,
				(f32(cell_y) + jitter_y) * config.cell_world_size,
			}
			if !_feature_placement_separated(output[:count], position, config.minimum_separation) {
				continue
			}
			scale_unit := f32((key >> 48) & 0xFF) / 255
			output[count] = {
				key      = key,
				cell     = {cell_x, cell_y},
				position = position,
				yaw      = f32((key >> 56) & 0xFF) / 255 * 2 * math.PI,
				scale    = config.scale_minimum + (config.scale_maximum - config.scale_minimum) * scale_unit,
			}
			count += 1
		}
	}
	return count, true
}

feature_placement_config_validate :: proc(
	config: Feature_Placement_Config,
	output_length: int,
) -> bool {
	if config.minimum_cell.x > config.maximum_cell.x do return false
	if config.minimum_cell.y > config.maximum_cell.y do return false
	if config.cluster_cells <= 0 do return false
	if config.chance > FEATURE_CHANCE_SCALE do return false
	if config.cell_world_size <= 0 do return false
	if config.jitter < 0 || config.jitter > 1 do return false
	if config.minimum_separation < 0 do return false
	if config.scale_minimum <= 0 || config.scale_maximum < config.scale_minimum do return false
	if config.output_limit == 0 || int(config.output_limit) > output_length do return false
	if int(config.output_limit) > FEATURE_PLACEMENT_LIMIT do return false
	return true
}

feature_placement_hash :: proc(seed, salt: u64, cluster_x, cluster_y: i32) -> u64 {
	value := seed ~ salt
	value ~= u64(i64(cluster_x)) * 0x9E3779B185EBCA87
	value ~= u64(i64(cluster_y)) * 0xC2B2AE3D27D4EB4F
	value ~= value >> 30
	value *= 0xBF58476D1CE4E5B9
	value ~= value >> 27
	value *= 0x94D049BB133111EB
	return value ~ (value >> 31)
}

@(private)
_feature_floor_div :: proc(value, divisor: i32) -> i32 {
	assert(divisor > 0, "_feature_floor_div: non-positive divisor")
	quotient := value / divisor
	if value < 0 && value % divisor != 0 do quotient -= 1
	return quotient
}

@(private)
_feature_placement_separated :: proc(
	placements: []Feature_Placement,
	position: [2]f32,
	minimum: f32,
) -> bool {
	assert(minimum >= 0, "_feature_placement_separated: negative minimum")
	minimum_squared := minimum * minimum
	for placement in placements {
		delta_x := position.x - placement.position.x
		delta_y := position.y - placement.position.y
		if delta_x * delta_x + delta_y * delta_y < minimum_squared do return false
	}
	return true
}

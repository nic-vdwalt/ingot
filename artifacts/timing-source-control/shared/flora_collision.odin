package shared

FLORA_LOGICAL_HASH_MASK :: u64(0x1FF)
FLORA_LOGICAL_TREE_RADIUS_MM :: u32(900)
FLORA_LOGICAL_BOULDER_RADIUS_MM :: u32(800)

Flora_Logical_Kind :: enum u8 {
	None,
	Conifer_A,
	Conifer_B,
	Baobab,
	Boulder_A,
	Boulder_B,
	Boulder_C,
}

Flora_Logical_Sample :: struct {
	height_fixed: i32,
	sea_fixed:    i32,
	snow_fixed:   i32,
	moisture:     u8,
	slope:        u16,
	biome:        Biome_Id,
}

Flora_Logical_Result :: struct {
	kind:                Flora_Logical_Kind,
	scale_channel:       u16,
	collision_radius_mm: u32,
}

flora_logical_hash :: proc(seed: u64, cell_x, cell_y: i32) -> u64 {
	value := (seed ~ 0xF10AA_5EED) ~ u64(i64(cell_x)) * 0x9E3779B185EBCA87
	value ~= u64(i64(cell_y)) * 0xC2B2AE3D27D4EB4F
	return flora_logical_mix(value)
}

flora_logical_mix :: proc(input: u64) -> u64 {
	value := input
	value ~= value >> 30
	value *= 0xBF58476D1CE4E5B9
	value ~= value >> 27
	value *= 0x94D049BB133111EB
	return value ~ (value >> 31)
}

flora_logical_channel :: proc(hash: u64, channel: u32) -> u16 {
	assert(channel < 7, "flora_logical_channel: channel out of range")
	return u16((hash >> (channel * 9)) & FLORA_LOGICAL_HASH_MASK)
}

flora_logical_solid :: proc(seed: u64, hash: u64, sample: Flora_Logical_Sample) -> Flora_Logical_Result {
	result := Flora_Logical_Result{scale_channel = flora_logical_channel(hash, 5)}
	variant := flora_logical_channel(hash, 4)
	tree_roll := flora_logical_channel(flora_logical_mix(hash ~ 0x71EE_5EED), 0)
	boulder_roll := flora_logical_channel(flora_logical_mix(hash ~ 0xB0A1_DE55), 0)
	if _flora_logical_tree_accepts(seed, hash, sample, tree_roll) {
		result.kind = _flora_logical_tree_kind(sample, variant)
		result.collision_radius_mm = FLORA_LOGICAL_TREE_RADIUS_MM
		return result
	}
	steep := sample.slope > 115 && sample.slope < 358
	alpine := sample.height_fixed > sample.snow_fixed - 10
	above_sea := sample.height_fixed > sample.sea_fixed + 1
	if (steep || alpine) && above_sea && boulder_roll < 26 {
		result.kind = Flora_Logical_Kind(int(Flora_Logical_Kind.Boulder_A) + min(int(variant) * 3 / 512, 2))
		result.collision_radius_mm = FLORA_LOGICAL_BOULDER_RADIUS_MM
	}
	return result
}

_flora_logical_tree_accepts :: proc(
	seed: u64,
	hash: u64,
	sample: Flora_Logical_Sample,
	roll: u16,
) -> bool {
	if sample.height_fixed <= sample.sea_fixed + 2 do return false
	if sample.height_fixed >= sample.snow_fixed - 2 do return false
	if sample.slope >= 140 do return false
	if sample.moisture <= 115 do return false
	region_x := i32((hash >> 48) & 0xF)
	region_y := i32((hash >> 52) & 0xF)
	region_hash := flora_logical_hash(seed ~ 0x6A0E_5EED, region_x, region_y)
	grove := 150 + u32(flora_logical_channel(region_hash, 1)) * 850 / 511
	chance := min(u32(sample.moisture - 115) * 1100 / 255, u32(420))
	chance = chance * grove / 1000
	chance = chance * _flora_logical_tree_density_permille(sample.biome) / 1000
	return u32(roll) * 1000 < chance * 512
}

_flora_logical_tree_kind :: proc(sample: Flora_Logical_Sample, variant: u16) -> Flora_Logical_Kind {
	switch sample.biome {
	case .Taiga, .Snowlands, .Tundra, .Mountain:
		return .Conifer_A if variant < 256 else .Conifer_B
	case .Savannah, .Desert:
		return .Baobab
	case .Ocean, .Lake, .Coast, .Wetland, .Grassland, .Forest:
	}
	altitude_numerator := max(sample.height_fixed - sample.sea_fixed, 0)
	altitude_denominator := max(sample.snow_fixed - sample.sea_fixed, 1)
	threshold := 179 + min(altitude_numerator * 256 / altitude_denominator, 256)
	if i32(variant) < threshold do return .Conifer_A if variant < 256 else .Conifer_B
	return .Baobab
}

_flora_logical_tree_density_permille :: proc(biome: Biome_Id) -> u32 {
	switch biome {
	case .Ocean, .Lake: return 0
	case .Coast: return 200
	case .Desert: return 30
	case .Savannah, .Mountain: return 250
	case .Snowlands: return 100
	case .Tundra: return 150
	case .Wetland: return 500
	case .Grassland: return 450
	case .Taiga: return 1400
	case .Forest: return 1600
	}
	return 450
}

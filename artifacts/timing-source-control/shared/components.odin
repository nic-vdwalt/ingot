package shared

import procgen "ingot:procgen"

// Component definitions for TerraForger's authoritative simulation. Every
// field the simulation reads or writes is integer-typed so tick results are
// bit-identical across platforms; the render-facing f32 position is derived
// from grid coordinates (exactly representable) and never read back by sim.

Resource_Kind :: enum u8 {
	Ore,
	Energy,
}

Building_Kind :: enum u8 {
	Headquarters,
	Mine,
	Solar_Array,
	Habitat,
}

// Transform is authoritative on the grid; position is the derived world-space
// render anchor kept alongside so render systems need no extra lookup.
Transform :: struct {
	face:     procgen.Terrain_Face_V4,
	grid_x:   i32,
	grid_y:   i32,
	position: [3]f32,
	up:       [3]f32,
	east:     [3]f32,
	north:    [3]f32,
}

// Net_Id is the stable cross-world identity used for replication. Server and
// client generational entity ids are never assumed equal; this is the bridge.
Net_Id :: distinct u64

Owner :: struct {
	player: u32,
}

// Efficiency is a percentage in [MIN_EFFICIENCY, MAX_EFFICIENCY]; the default
// is 100 and mini-game results adjust it through validated commands only.
Building :: struct {
	kind:               Building_Kind,
	level:              u8,
	efficiency_percent: u8,
}

Construction :: struct {
	ticks_remaining: u32,
	target_level:    u8,
}

Stockpile :: struct {
	amounts: [Resource_Kind]u64,
}

// Resource_Node marks a map tile entity; a Mine built on the same entity
// scales its yield by richness_percent.
Resource_Node :: struct {
	kind:             Resource_Kind,
	richness_percent: u32,
}

Harvest_Link :: struct {
	node: Net_Id,
}

MIN_EFFICIENCY :: u8(50)
MAX_EFFICIENCY :: u8(150)
DEFAULT_EFFICIENCY :: u8(100)
MAX_BUILDING_LEVEL :: u8(20)

GRID_CELL_SIZE :: f32(2.0)

// building_footprint returns the NxN cell size of a kind. The transform's
// grid_x/grid_y is the footprint's minimum corner; the building occupies
// [grid_x, grid_x+w) x [grid_y, grid_y+h).
building_footprint :: proc(kind: Building_Kind) -> (w: i32, h: i32) {
	switch kind {
	case .Headquarters:
		return 3, 3
	case .Habitat:
		return 2, 2
	case .Solar_Array:
		return 2, 2
	case .Mine:
		return 1, 1
	}
	return 1, 1
}

// building_harvests returns the resource kind a building may sit on (and
// harvest); ok=false means the footprint must avoid all resource nodes.
building_harvests :: proc(kind: Building_Kind) -> (Resource_Kind, bool) {
	switch kind {
	case .Mine:
		return .Ore, true
	case .Solar_Array:
		return .Energy, true
	case .Headquarters, .Habitat:
		return .Ore, false
	}
	return .Ore, false
}

// transform_make derives the render position from grid coordinates (Z-up
// world, buildings anchored on the terrain surface). Grid coordinates times a
// power-of-two cell size are exactly representable in f32, and the effective
// terrain height is a pure function of the shared seed plus the world's
// heightfield, so the derivation is deterministic and never feeds back into
// the sim. For multi-cell buildings the grid anchor is the footprint's
// minimum corner; _apply_place re-samples position.z after flattening.
transform_make :: proc(world: ^World, grid_x: i32, grid_y: i32) -> Transform {
	assert(world != nil, "transform_make: nil world")
	assert(grid_x >= -1_000_000 && grid_x <= 1_000_000, "transform_make: grid_x out of range")
	assert(grid_y >= -1_000_000 && grid_y <= 1_000_000, "transform_make: grid_y out of range")
	world_x := f32(grid_x) * GRID_CELL_SIZE
	world_y := f32(grid_y) * GRID_CELL_SIZE
	position := [3]f32{world_x, world_y, terrain_height(world, world_x, world_y)}
	return Transform {
		grid_x = grid_x,
		grid_y = grid_y,
		position = position,
		up = {0, 0, 1},
		east = {1, 0, 0},
		north = {0, 1, 0},
	}
}

planet_transform_make :: proc(coord: Planet_Coord, height: f32) -> Transform {
	assert(planet_coord_valid(coord), "planet_transform_make: invalid coordinate")
	direction := planet_direction(coord)
	up, east, north := planet_basis(direction)
	return Transform {
		face = coord.face,
		grid_x = coord.u,
		grid_y = coord.v,
		position = planet_position(direction, height),
		up = up,
		east = east,
		north = north,
	}
}

// building_yield_per_tick returns the base resource output for one sim tick
// before efficiency and node-richness scaling. Integer math only.
building_yield_per_tick :: proc(kind: Building_Kind, level: u8) -> (Resource_Kind, u64) {
	assert(level <= MAX_BUILDING_LEVEL, "building_yield_per_tick: level out of range")
	level_scale := u64(level)
	switch kind {
	case .Mine:
		return .Ore, 2 * level_scale
	case .Solar_Array:
		return .Energy, 3 * level_scale
	case .Headquarters, .Habitat:
		return .Ore, 0
	}
	return .Ore, 0
}

// building_cost returns the stockpile cost to start construction of the next
// level. Level here is the level being built (target level, starting at 1).
building_cost :: proc(kind: Building_Kind, target_level: u8) -> [Resource_Kind]u64 {
	assert(target_level >= 1, "building_cost: target level below 1")
	assert(target_level <= MAX_BUILDING_LEVEL, "building_cost: target level out of range")
	scale := u64(target_level)
	cost: [Resource_Kind]u64
	switch kind {
	case .Headquarters:
		cost[.Ore] = 50 * scale
		cost[.Energy] = 20 * scale
	case .Mine:
		cost[.Ore] = 10 * scale
		cost[.Energy] = 5 * scale
	case .Solar_Array:
		cost[.Ore] = 15 * scale
	case .Habitat:
		cost[.Ore] = 20 * scale
		cost[.Energy] = 10 * scale
	}
	return cost
}

// building_build_ticks returns how many sim ticks construction of the target
// level takes; linear in level so upgrades stay meaningful long-term.
building_build_ticks :: proc(kind: Building_Kind, target_level: u8) -> u32 {
	assert(target_level >= 1, "building_build_ticks: target level below 1")
	assert(target_level <= MAX_BUILDING_LEVEL, "building_build_ticks: target level out of range")
	base: u32
	switch kind {
	case .Headquarters:
		base = 8
	case .Mine:
		base = 4
	case .Solar_Array:
		base = 4
	case .Habitat:
		base = 6
	}
	return base * u32(target_level)
}

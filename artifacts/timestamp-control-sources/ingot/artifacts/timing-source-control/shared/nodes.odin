package shared

import ecs "ingot:ecs"
import procgen "ingot:procgen"

// Deterministic resource-node scattering derived from TERRAIN_SEED. The world
// is split into square clusters of grid cells; each cluster hashes to at most
// one candidate node whose cell must be buildable on the pristine terrain.
// Client and server call world_populate_nodes once after world_init and get
// bit-identical layouts, so nodes never need replication or persistence
// beyond the ECS snapshot itself.

// Cluster side length in grid cells; 8 cells = 16 world units between
// candidate sites, giving a 16x16 cluster grid over the 128x128-cell world.
NODE_CLUSTER_CELLS :: i32(8)
// Percent of clusters that host an ore node / an energy vent. Energy is rare
// so solar placement stays a real decision.
NODE_ORE_PERCENT :: u64(24)
NODE_ENERGY_PERCENT :: u64(6)

// Richness tiers with weights 4/3/2/1 in 10: common nodes are mild, rich
// nodes are rare. Values satisfy spawn_resource_node's [100, 400] contract.
NODE_RICHNESS_TIERS := [4]u32{125, 150, 200, 300}

Node_Biome_Profile :: struct {
	ore_percent:    u8,
	energy_percent: u8,
}

NODE_BIOME_PROFILES := [Biome_Id]Node_Biome_Profile {
	.Ocean     = {},
	.Lake      = {},
	.Coast     = {8, 4},
	.Wetland   = {14, 4},
	.Grassland = {24, 6},
	.Savannah  = {20, 9},
	.Forest    = {20, 4},
	.Taiga     = {22, 5},
	.Desert    = {18, 12},
	.Tundra    = {22, 5},
	.Snowlands = {26, 6},
	.Mountain  = {32, 8},
}

// world_populate_nodes scatters nodes over the whole world. Must run on a
// freshly initialised world (zero heightfield) so the buildability gate sees
// the analytic base terrain identically everywhere. Returns false only on
// entity exhaustion.
world_populate_nodes :: proc(world: ^World) -> (count: u32, ok: bool) {
	assert(world != nil, "world_populate_nodes: nil world")
	assert(ecs.set_len(&world.nodes) == 0, "world_populate_nodes: nodes already present")
	cluster_count := PLANET_FACE_CELLS / NODE_CLUSTER_CELLS
	for face in procgen.Terrain_Face_V4 {
		for cluster_v in 0 ..< cluster_count {
			for cluster_u in 0 ..< cluster_count {
				hash := _node_hash(world.foundation.seed, i32(face) * cluster_count + cluster_u, cluster_v)
				cell_u := cluster_u * NODE_CLUSTER_CELLS + i32((hash >> 8) % u64(NODE_CLUSTER_CELLS))
				cell_v := cluster_v * NODE_CLUSTER_CELLS + i32((hash >> 16) % u64(NODE_CLUSTER_CELLS))
				coord := Planet_Coord{face, cell_u, cell_v}
				if !planet_coord_valid(coord) do continue
				if !planet_placement_allowed(world, coord) do continue
				sample := terrain_sample_at_coord(world, coord)
				profile := NODE_BIOME_PROFILES[sample.primary_biome]
				roll := u8(hash % 100)
				kind := Resource_Kind.Ore
				if roll >= profile.ore_percent {
					if roll >= profile.ore_percent + profile.energy_percent do continue
					kind = .Energy
				}
				tier := min(_node_tier(hash) + int(sample.ruggedness > 0.72), 3)
				richness := NODE_RICHNESS_TIERS[tier]
				_, spawned := spawn_resource_node(world, coord, kind, richness)
				if !spawned do return count, false
				count += 1
			}
		}
	}
	return count, true
}

world_clear_resource_nodes :: proc(world: ^World) -> u32 {
	assert(world != nil, "world_clear_resource_nodes: nil world")
	assert(world.pool.capacity > 0, "world_clear_resource_nodes: world not initialised")
	ecs.flush(&world.pool, &world.deferred)
	cleared := u32(0)
	index := u32(0)
	for index < ecs.set_len(&world.nodes) {
		entity := world.nodes.header.entities[index]
		if ecs.has(&world.buildings, entity) {
			index += 1
			continue
		}
		assert(
			world_destroy_entity(world, entity),
			"world_clear_resource_nodes: destroy failed",
		)
		cleared += 1
	}
	return cleared
}

// _node_tier maps hash bits to a tier index with weights 4/3/2/1.
_node_tier :: proc(hash: u64) -> int {
	assert(len(NODE_RICHNESS_TIERS) == 4, "_node_tier: tier table changed")
	roll := (hash >> 24) % 10
	if roll < 4 do return 0
	if roll < 7 do return 1
	if roll < 9 do return 2
	return 3
}

// _node_hash is a splitmix-style avalanche over seed and cluster coords,
// integer-only so WASM and native agree bit-for-bit. Casts go through i64 so
// negative cluster coordinates sign-extend identically everywhere.
_node_hash :: proc(seed: u64, cluster_x, cluster_y: i32) -> u64 {
	assert(NODE_CLUSTER_CELLS > 0, "_node_hash: degenerate cluster size")
	value := seed ~ u64(i64(cluster_x)) * 0x9E3779B185EBCA87
	value ~= u64(i64(cluster_y)) * 0xC2B2AE3D27D4EB4F
	value ~= value >> 30
	value *= 0xBF58476D1CE4E5B9
	value ~= value >> 27
	value *= 0x94D049BB133111EB
	return value ~ (value >> 31)
}

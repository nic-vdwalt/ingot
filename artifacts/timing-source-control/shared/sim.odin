package shared

import ecs "ingot:ecs"

// The authoritative simulation advances in fixed ticks. Systems are pure
// functions of (world, tick): no wall clock, no floats in state mutation, so
// the same command sequence yields byte-identical snapshots everywhere.

TICKS_PER_SECOND :: u32(4)
TICK_DURATION_SECONDS :: f64(1.0) / f64(TICKS_PER_SECOND)

Planetary_Summary :: struct {
	temperature_mk:  i32,
	pressure_pa:     u32,
	humidity:        u32,
	precipitation:   u32,
	wind_speed:      u32,
	current_speed:   u32,
	tide_mm:         u32,
	wave_height_mm:  u32,
	crust_age_ka:    u32,
	heat_flux_mw_m2: u32,
	volcanoes:       u16,
	vents:           u16,
	dormant_vents:   u16,
	extinct_vents:   u16,
	surface_par:     u32,
	benthic_par:     u32,
	oxygenated:      u32,
	anoxic:          u32,
	diagnostic_steps: u64,
}

// sim_tick runs one fixed step. The deferred buffer is flushed between
// systems so structural changes recorded by one system are visible to the
// next but never move dense arrays under a live iterator. `timing`, when
// given, receives a per-stage wall-clock breakdown for profiling.
sim_tick :: proc(world: ^World, tick: u64, timing: ^Sim_Tick_Timing = nil) {
	_sim_tick(world, tick, nil, nil, timing)
}

// sim_tick_prepared is sim_tick with the planetary simulated stage already
// computed for this exact tick in `prepared` (see world_planetary_commit):
// the stage is committed by swapping states instead of being recomputed.
// Every other system runs exactly as in sim_tick, in the same order.
sim_tick_prepared :: proc(
	world: ^World,
	tick: u64,
	prepared: ^Planetary_State,
	scratch: ^Planetary_State,
	timing: ^Sim_Tick_Timing = nil,
) {
	assert(prepared != nil && scratch != nil, "sim_tick_prepared: nil prepared state")
	_sim_tick(world, tick, prepared, scratch, timing)
}

@(private = "file")
_sim_tick :: proc(
	world: ^World,
	tick: u64,
	prepared: ^Planetary_State,
	scratch: ^Planetary_State,
	timing: ^Sim_Tick_Timing,
) {
	assert(world != nil, "sim_tick: nil world")
	assert(world.pool.capacity > 0, "sim_tick: world not initialised")
	sim_timing_begin(timing, tick)
	system_construction(world, tick)
	ecs.flush(&world.pool, &world.deferred)
	sim_timing_mark(timing, .Construction)
	system_production(world, tick)
	ecs.flush(&world.pool, &world.deferred)
	sim_timing_mark(timing, .Production)
	_ = waterfield_step(world, tick)
	sim_timing_mark(timing, .Waterfield)
	if prepared != nil {
		world_planetary_commit(world, tick, prepared, scratch, timing)
	} else {
		world_planetary_step(world, tick, timing)
	}
	world_ecology_step(world, tick)
	sim_timing_mark(timing, .Ecology)
	ecs.flush(&world.pool, &world.deferred)
	sim_timing_mark(timing, .Flush)
	sim_timing_end(timing)
}

// system_construction ticks down active constructions; on completion the
// building takes its target level and the construction component is removed
// (deferred, because we are iterating the construction set).
system_construction :: proc(world: ^World, tick: u64) {
	assert(world != nil, "system_construction: nil world")
	assert(tick < max(u64), "system_construction: tick overflow")
	it := ecs.iter2(&world.buildings, &world.constructions)
	for {
		entity, building, construction, ok := ecs.iter2_next(&it)
		if !ok do break
		assert(construction.target_level > building.level, "construction target not above level")
		if construction.ticks_remaining > 1 {
			construction.ticks_remaining -= 1
			continue
		}
		building.level = construction.target_level
		// A fresh (or upgraded) building starts at default efficiency; the
		// player can push it up again through the infrastructure mini-game.
		building.efficiency_percent = DEFAULT_EFFICIENCY
		if !ecs.defer_remove(&world.deferred, &world.constructions, entity) {
			// Deferred capacity is sized for MAX_DEFERRED_COMMANDS structural
			// changes per system; overflowing it is a design bug, not data.
			assert(false, "system_construction: deferred buffer overflow")
		}
	}
}

// system_production credits each completed building's yield to its owner's
// stockpile, scaled by building efficiency and (for mines on a node) the
// node's richness. Integer math throughout.
system_production :: proc(world: ^World, tick: u64) {
	assert(world != nil, "system_production: nil world")
	assert(tick < max(u64), "system_production: tick overflow")
	it := ecs.iter2(&world.buildings, &world.owners)
	for {
		entity, building, owner, ok := ecs.iter2_next(&it)
		if !ok do break
		// Buildings under construction (level 0 or upgrading) still produce
		// at their current completed level; level 0 produces nothing.
		if building.level == 0 do continue
		kind, base_yield := building_yield_per_tick(building.kind, building.level)
		if base_yield == 0 do continue
		amount := base_yield * u64(building.efficiency_percent) / 100
		if link, has_link := ecs.get(&world.harvest_links, entity); has_link {
			if node_entity, found := world_entity_by_net_id(world, link.node); found {
				if node, has_node := ecs.get(&world.nodes, node_entity); has_node && node.kind == kind {
					amount = amount * u64(node.richness_percent) / 100
				}
			}
		}
		if amount == 0 do continue
		assert(owner.player < MAX_PLAYERS, "system_production: player id out of range")
		player_entity := world.players[owner.player]
		stockpile, has_stockpile := ecs.get(&world.stockpiles, player_entity)
		if !has_stockpile do continue
		assert(stockpile.amounts[kind] <= max(u64) - amount, "system_production: overflow")
		stockpile.amounts[kind] += amount
	}
}

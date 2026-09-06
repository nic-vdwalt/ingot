package shared

import ecs "ingot:ecs"

ECOLOGY_REPRODUCTION_ENERGY :: u64(10_000)

ecology_reproduction_step :: proc(world: ^World, tick: u64) {
	assert(world != nil, "ecology reproduction: nil world")
	_ = tick
	for index in 0 ..< ecs.set_len(&world.reproductions) {
		entity := world.reproductions.header.entities[index]
		reproduction := &world.reproductions.items[index]
		organism, has_organism := ecs.get(&world.organisms, entity)
		if !has_organism || organism.stage != .Adult do continue
		if organism.age_ticks < reproduction.maturity_ticks do continue
		if reproduction.remaining_ticks > 0 do continue
		if organism.energy < ECOLOGY_REPRODUCTION_ENERGY do continue
		organism.energy -= ECOLOGY_REPRODUCTION_ENERGY
		reproduction.remaining_ticks = reproduction.cooldown_ticks
	}
}

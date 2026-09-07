package shared

world_ecology_step :: proc(world: ^World, tick: u64) {
	assert(world != nil, "world_ecology_step: nil world")
	if tick % FLORA_ECOLOGY_CADENCE_TICKS == 0 do flora_ecology_step_state(&world.flora_ecology, world)
	if tick % MARINE_CADENCE_TICKS == 0 do marine_ecology_step_state(&world.marine_ecology, world)
}

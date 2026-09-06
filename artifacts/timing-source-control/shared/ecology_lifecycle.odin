package shared

import ecs "ingot:ecs"

ecology_lifecycle_step :: proc(world: ^World) {
	assert(world != nil, "ecology lifecycle: nil world")
	for index in 0 ..< ecs.set_len(&world.organisms) {
		entity := world.organisms.header.entities[index]
		organism := &world.organisms.items[index]
		if organism.age_ticks < max(u64) do organism.age_ticks += 1
		if reproduction, ok := ecs.get(&world.reproductions, entity); ok && reproduction.remaining_ticks > 0 {
			reproduction.remaining_ticks -= 1
		}
		if organism.health == 0 {
			if !ecs.defer_destroy(&world.deferred, entity) {
				assert(false, "ecology lifecycle: deferred buffer overflow")
			}
		}
	}
}

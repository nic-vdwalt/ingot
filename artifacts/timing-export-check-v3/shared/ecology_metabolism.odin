package shared

import ecs "ingot:ecs"

ecology_metabolism_step :: proc(world: ^World) {
	assert(world != nil, "ecology metabolism: nil world")
	it := ecs.iter2(&world.organisms, &world.metabolisms)
	for {
		entity, organism, metabolism, ok := ecs.iter2_next(&it)
		if !ok do break
		transform, located := ecs.get(&world.transforms, entity)
		if !located do continue
		environment := ecology_environment_at_transform(world, transform)
		available := min(environment.chemistry, metabolism.intake_per_step)
		organism.energy += u64(available)
		maintenance := u64(metabolism.maintenance_per_step)
		if organism.energy > maintenance {
			organism.energy -= maintenance
		} else {
			organism.energy = 0
			organism.health = organism.health - 1 if organism.health > 0 else 0
		}
	}
}

package shared

import "core:testing"

@(test)
marine_world_cadence_and_snapshot :: proc(t: ^testing.T) {
	world := new(World)
	defer free(world)
	testing.expect(t, world_init(world))
	defer world_deinit(world)
	state := &world.marine_ecology
	testing.expect(t, len(state.cells) == PLANET_SIM_CELL_COUNT)
	testing.expect(t, marine_total_mass(state) == state.initial_mass)
	world_ecology_step(world, 1)
	testing.expect(t, state.step == 0)
	world_ecology_step(world, MARINE_CADENCE_TICKS)
	testing.expect(t, state.step == 1 && state.elapsed_seconds == MARINE_STEP_SECONDS && !state.frozen)
	buffer := make([]u8, world_snapshot_size(world))
	defer delete(buffer)
	_, ok := world_snapshot_write(world, buffer)
	testing.expect(t, ok)
	world_ecology_step(world, 2 * MARINE_CADENCE_TICKS)
	mass, serial := marine_total_mass(state), state.birth_serial
	testing.expect(t, world_snapshot_read(world, buffer))
	testing.expect(t, state.step == 1)
	world_ecology_step(world, 2 * MARINE_CADENCE_TICKS)
	testing.expect(t, state.step == 2 && marine_total_mass(state) == mass && state.birth_serial == serial)
}

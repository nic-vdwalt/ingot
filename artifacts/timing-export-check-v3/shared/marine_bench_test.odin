package shared

import "core:fmt"
import "core:mem"
import "core:testing"
import "core:time"

when BENCH_ENABLED {
	@(test)
	bench_marine_ownership_and_snapshot :: proc(t: ^testing.T) {
		marine_ownership_measure(t)
	}
}

marine_ownership_measure :: proc(t: ^testing.T) {
	{
		world := new(World)
		defer free(world)
		testing.expect(t, world_init(world))
		defer world_deinit(world)
		state := &world.marine_ecology
		started := time.tick_now()
		for _ in 0 ..< 5 do marine_initial_diagnostics(state)
		fmt.printf("[marine bench] initial diagnostics mean %.3f ms\n", time.duration_milliseconds(time.tick_diff(started, time.tick_now())) / 5)
		owner := state.allocator
		tracker := Marine_Test_Allocator{backing = owner}
		state.allocator = mem.Allocator{procedure = marine_test_allocator_proc, data = &tracker}
		for iteration in 0 ..< 5 {
			started = time.tick_now()
			marine_ecology_step_state(state, world)
			fmt.printf("[marine bench] live hour %d %.3f ms\n", iteration, time.duration_milliseconds(time.tick_diff(started, time.tick_now())))
		}
		state.allocator = owner
		fmt.printf("[marine bench] five hours allocations %d outstanding %d\n", tracker.calls, tracker.outstanding)
		testing.expect(t, tracker.calls == 10 && tracker.outstanding == 0)
		marine_bytes := make([]u8, marine_ecology_snapshot_size(state))
		defer delete(marine_bytes)
		_, saved := marine_ecology_snapshot_write(state, marine_bytes)
		testing.expect(t, saved)
		for iteration in 0 ..< 3 {
			decoded: Marine_Ecology
			started = time.tick_now()
			testing.expect(t, marine_ecology_snapshot_read(&decoded, marine_bytes))
			fmt.printf("[marine bench] standalone decode %d %.3f ms\n", iteration, time.duration_milliseconds(time.tick_diff(started, time.tick_now())))
			marine_ecology_deinit(&decoded)
		}
		buffer := make([]u8, world_snapshot_size(world))
		defer delete(buffer)
		for iteration in 0 ..< 3 {
			started = time.tick_now()
			_, ok := world_snapshot_write(world, buffer)
			testing.expect(t, ok)
			fmt.printf("[marine bench] world write %d %.3f ms\n", iteration, time.duration_milliseconds(time.tick_diff(started, time.tick_now())))
			started = time.tick_now()
			testing.expect(t, world_snapshot_read(world, buffer))
			fmt.printf("[marine bench] world read %d %.3f ms\n", iteration, time.duration_milliseconds(time.tick_diff(started, time.tick_now())))
		}
	}
}

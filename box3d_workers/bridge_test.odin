package box3d_workers

import "core:testing"
import b3 "vendor:box3d"

@(test)
test_serial_configuration_is_unchanged :: proc(t: ^testing.T) {
	when !ENABLED {
		world_def := b3.DefaultWorldDef()
		before := world_def.workerCount
		configure_world(&world_def)
		testing.expect_value(t, world_def.workerCount, before)
		testing.expect_value(t, worker_count(), u32(1))
	}
}

@(test)
test_serial_requests_are_rejected :: proc(t: ^testing.T) {
	when !ENABLED {
		testing.expect(t, !request_step())
		testing.expect(t, !request_batch(1))
		testing.expect(t, !request_command(1, 0))
		testing.expect(t, !step_ready())
		testing.expect(t, !batch_ready())
		testing.expect(t, !command_ready())
	}
}

#assert(TASK_MAX > 0)
#assert(WAIT_TIMEOUT_NS > 0)

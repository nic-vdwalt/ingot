package gfx

import "core:testing"

@(test)
gpu_timing_query_pairs_are_bounded :: proc(t: ^testing.T) {
	state: Gpu_Timing_State
	state.available = true
	state.active_slot = 0
	state.slots[0].query_count = GPU_TIMING_QUERY_COUNT - 2
	testing.expect(t, _gpu_timing_pair_reserve(&state).valid)
	testing.expect(t, !_gpu_timing_pair_reserve(&state).valid)
}

@(test)
gpu_timing_ticks_sum_completed_spans :: proc(t: ^testing.T) {
	ticks := [4]u64{100, 150, 200, 280}
	seconds, ok := _gpu_timing_seconds(ticks[:], 2, 1)
	testing.expect(t, ok)
	testing.expect_value(t, seconds, f64(130e-9))
}

@(test)
gpu_timing_rejects_reversed_timestamps :: proc(t: ^testing.T) {
	ticks := [2]u64{200, 100}
	_, ok := _gpu_timing_seconds(ticks[:], 1, 1)
	testing.expect(t, !ok)
}

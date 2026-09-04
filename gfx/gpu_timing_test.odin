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
	labels := [1]Gpu_Timing_Label{_gpu_timing_label("bad")}
	_, ok = _gpu_timing_detail(ticks[:], labels[:], 1, 1)
	testing.expect(t, !ok)
}

@(test)
gpu_timing_labels_are_copied_and_bounded :: proc(t: ^testing.T) {
	name := [8]u8{'m', 'u', 't', 'a', 'b', 'l', 'e', 0}
	label := _gpu_timing_label(string(name[:7]))
	name[0] = 'x'
	testing.expect_value(t, label.length, u8(7))
	testing.expect_value(t, label.bytes[0], u8('m'))
	long := _gpu_timing_label("abcdefghijklmnopqrstuvwxyz0123456789")
	testing.expect_value(t, long.length, u8(GPU_TIMING_LABEL_MAX))
}

@(test)
gpu_timing_detail_aggregates_repeated_labels :: proc(t: ^testing.T) {
	ticks := [6]u64{100, 150, 200, 280, 300, 330}
	labels := [3]Gpu_Timing_Label {
		_gpu_timing_label("world.ocean"),
		_gpu_timing_label("world.opaque"),
		_gpu_timing_label("world.ocean"),
	}
	detail, ok := _gpu_timing_detail(ticks[:], labels[:], 3, 1)
	testing.expect(t, ok)
	testing.expect_value(t, detail.group_count, u32(2))
	testing.expect_value(t, detail.groups[0].count, u32(2))
	testing.expect_value(t, detail.groups[0].seconds, f64(80e-9))
	testing.expect_value(t, detail.groups[1].count, u32(1))
	testing.expect_value(t, detail.seconds, f64(160e-9))
}

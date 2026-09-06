#+build !js
package gfx

import "core:testing"

@(test)
gpu_timing_completion_queue_retains_order_and_reports_loss :: proc(t: ^testing.T) {
	state: Gpu_Timing_State
	_gpu_timing_enqueue(&state, {frame_index = 9, valid = true})
	_gpu_timing_enqueue(&state, {frame_index = 3, valid = true})
	output: [2]Gpu_Frame_Timing_Detail
	count, health := _gpu_timing_drain(&state, output[:1])
	testing.expect_value(t, count, 1)
	testing.expect_value(t, output[0].frame_index, u64(9))
	testing.expect_value(t, health.overflow, u64(0))
	testing.expect_value(t, health.completion_occupancy, u32(1))
	testing.expect_value(t, health.completion_high_water, u32(2))
	count, health = _gpu_timing_drain(&state, output[:])
	testing.expect_value(t, count, 1)
	testing.expect_value(t, output[0].frame_index, u64(3))
	testing.expect_value(t, health.completion_occupancy, u32(0))
	testing.expect_value(t, health.completion_high_water, u32(1))
	testing.expect_value(t, state.latest.frame_index, u64(9))
	for index in 0 ..< GPU_TIMING_COMPLETION_CAPACITY + 2 {
		_gpu_timing_enqueue(&state, {frame_index = u64(index + 10), valid = true})
	}
	count, health = _gpu_timing_drain(&state, output[:])
	testing.expect_value(t, count, 2)
	testing.expect_value(t, health.overflow, u64(2))
	testing.expect_value(t, health.completion_occupancy, u32(GPU_TIMING_COMPLETION_CAPACITY - 2))
	testing.expect_value(t, health.completion_high_water, u32(GPU_TIMING_COMPLETION_CAPACITY))
	testing.expect_value(t, output[0].frame_index, u64(10))
	_, health = _gpu_timing_drain(&state, nil)
	testing.expect_value(t, health.overflow, u64(0))
	testing.expect_value(t, health.completion_occupancy, u32(GPU_TIMING_COMPLETION_CAPACITY - 2))
	testing.expect_value(t, health.completion_high_water, u32(GPU_TIMING_COMPLETION_CAPACITY - 2))
}

@(test)
gpu_timing_collect_preserves_every_completion :: proc(t: ^testing.T) {
	ctx := new(Context)
	defer free(ctx)
	ctx.gpu_timing.available = true
	ctx.gpu_timing.timestamp_period = 1
	for &slot, index in ctx.gpu_timing.slots {
		slot.in_flight = true
		slot.map_done = true
		slot.map_ok = true
		slot.frame_index = u64(GPU_TIMING_FRAME_SLOTS - index)
		slot.query_count = 2
		slot.ticks[0] = 10
		slot.ticks[1] = 20
	}
	output: [GPU_TIMING_FRAME_SLOTS]Gpu_Frame_Timing_Detail
	count, health := context_renderer_gpu_timing_drain(ctx, output[:])
	testing.expect_value(t, count, GPU_TIMING_FRAME_SLOTS)
	testing.expect_value(t, health.map_failure, u64(0))
	testing.expect_value(t, health.overflow, u64(0))
	testing.expect_value(t, health.completion_occupancy, u32(0))
	testing.expect_value(t, health.completion_high_water, u32(GPU_TIMING_FRAME_SLOTS))
	for detail, index in output {
		testing.expect_value(t, detail.frame_index, u64(GPU_TIMING_FRAME_SLOTS - index))
	}
	for &slot in ctx.gpu_timing.slots do slot.in_flight = true
	_gpu_timing_frame_begin(ctx)
	testing.expect_value(t, ctx.gpu_timing.health.no_free_slot, u64(1))
	ctx.gpu_timing.slots[0].map_done = true
	ctx.gpu_timing.slots[0].map_ok = false
	_gpu_timing_collect(ctx)
	testing.expect_value(t, ctx.gpu_timing.health.map_failure, u64(1))
}

@(test)
gpu_timing_health_preserves_invalid_and_truncated_evidence :: proc(t: ^testing.T) {
	ctx := new(Context)
	defer free(ctx)
	ctx.epoch = 12
	ctx.gpu_timing.available = true
	ctx.gpu_timing.timestamp_period = 1
	_gpu_timing_frame_begin(ctx)
	slot := &ctx.gpu_timing.slots[0]
	testing.expect_value(t, slot.epoch, u64(12))
	for index in 0 ..< GPU_TIMING_MAX_SPANS {
		label := [1]u8{u8(index + 1)}
		testing.expect(t, _gpu_timing_pair_reserve(&ctx.gpu_timing, string(label[:])).valid)
		slot.ticks[index * 2] = u64(index * 2)
		slot.ticks[index * 2 + 1] = u64(index * 2 + 1)
	}
	testing.expect(t, !_gpu_timing_pair_reserve(&ctx.gpu_timing).valid)
	slot.in_flight = true
	slot.map_done = true
	slot.map_ok = true
	output: [1]Gpu_Frame_Timing_Detail
	count, health := context_renderer_gpu_timing_drain(ctx, output[:])
	testing.expect_value(t, count, 1)
	testing.expect_value(t, output[0].epoch, u64(12))
	testing.expect_value(t, health.pair_exhaustion, u64(1))
	testing.expect_value(
		t,
		health.group_truncation,
		u64(GPU_TIMING_MAX_SPANS - GPU_TIMING_MAX_GROUPS),
	)
	slot.in_flight = true
	slot.map_done = true
	slot.map_ok = true
	slot.epoch = 23
	slot.frame_index = 45
	slot.query_count = 6
	slot.labels[0] = _gpu_timing_label("valid.before")
	slot.labels[1] = _gpu_timing_label("invalid.pair")
	slot.labels[2] = _gpu_timing_label("valid.after")
	slot.ticks[0] = 10
	slot.ticks[1] = 20
	slot.ticks[2] = 40
	slot.ticks[3] = 30
	slot.ticks[4] = 50
	slot.ticks[5] = 60
	count, health = context_renderer_gpu_timing_drain(ctx, output[:])
	testing.expect_value(t, count, 0)
	testing.expect_value(t, health.invalid_timestamps, u64(1))
	testing.expect(t, health.first_invalid_pair.valid)
	testing.expect_value(t, health.first_invalid_pair.epoch, u64(23))
	testing.expect_value(t, health.first_invalid_pair.frame_index, u64(45))
	testing.expect_value(t, health.first_invalid_pair.pair_index, u32(1))
	testing.expect(
		t,
		_gpu_timing_label_equal(
			health.first_invalid_pair.label,
			_gpu_timing_label("invalid.pair"),
		),
	)
	_, health = context_renderer_gpu_timing_drain(ctx, nil)
	testing.expect(t, !health.first_invalid_pair.valid)
}

@(test)
gpu_timing_pass_boundaries_reserve_distinct_indices :: proc(t: ^testing.T) {
	state: Gpu_Timing_State
	unavailable := _gpu_timing_pass_writes(&state, "window")
	testing.expect(t, unavailable.querySet == nil)
	testing.expect_value(t, state.slots[0].query_count, u32(0))
	state.available = true
	first := _gpu_timing_pass_writes(&state, "world.opaque")
	second := _gpu_timing_pass_writes(&state, "world.ocean")
	testing.expect_value(t, first.beginningOfPassWriteIndex, u32(0))
	testing.expect_value(t, first.endOfPassWriteIndex, u32(1))
	testing.expect_value(t, second.beginningOfPassWriteIndex, u32(2))
	testing.expect_value(t, second.endOfPassWriteIndex, u32(3))
	testing.expect_value(t, state.slots[0].query_count, u32(4))
	testing.expect(
		t,
		_gpu_timing_label_equal(state.slots[0].labels[1], _gpu_timing_label("world.ocean")),
	)
}

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
gpu_timing_query_pairs_require_active_available_slot :: proc(t: ^testing.T) {
	testing.expect(t, !_gpu_timing_pair_reserve(nil).valid)
	state: Gpu_Timing_State
	testing.expect(t, !_gpu_timing_pair_reserve(&state).valid)
	state.available = true
	state.active_slot = -1
	testing.expect(t, !_gpu_timing_pair_reserve(&state).valid)
	state.active_slot = GPU_TIMING_FRAME_SLOTS
	testing.expect(t, !_gpu_timing_pair_reserve(&state).valid)
	state.active_slot = GPU_TIMING_FRAME_SLOTS - 1
	state.slots[state.active_slot].in_flight = true
	testing.expect(t, !_gpu_timing_pair_reserve(&state).valid)
	state.slots[state.active_slot].in_flight = false
	token := _gpu_timing_pair_reserve(&state)
	testing.expect(t, token.valid)
	testing.expect_value(t, token.query_begin, u32(0))
	testing.expect_value(t, token.query_end, u32(1))
	testing.expect_value(t, state.slots[state.active_slot].query_count, u32(2))
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

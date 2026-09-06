#+build !js
package gfx

import "core:testing"

@(test)
presentation_host_ignores_missing_frame :: proc(t: ^testing.T) {
	ctx := new(Context)
	defer free(ctx)
	ctx.epoch = 1
	context_frame_delivery_record_host(ctx, 0.01, 0.002)
	testing.expect_value(t, ctx.delivery.dropped, u64(0))
	for slot in ctx.delivery.slots {
		testing.expect(t, !slot.active)
	}
}

@(test)
presentation_submission_ignores_missing_frame :: proc(t: ^testing.T) {
	ctx := new(Context)
	defer free(ctx)
	_frame_delivery_submitted(ctx, 0, 1)
	testing.expect_value(t, ctx.delivery.dropped, u64(0))
	for slot in ctx.delivery.slots {
		testing.expect(t, !slot.active)
	}
}

@(test)
presentation_records_valid_frame_and_rejects_stale_epoch :: proc(t: ^testing.T) {
	ctx := new(Context)
	defer free(ctx)
	ctx.epoch = 1
	ctx.stats_latest.frame_index = 1
	_frame_delivery_begin(ctx, 1)
	_frame_delivery_submitted(ctx, 1, 10)
	context_frame_delivery_record_host(ctx, 0.01, 0.002)
	slot := _frame_delivery_slot(ctx, 1)
	testing.expect(t, slot != nil)
	if slot == nil do return
	testing.expect_value(t, slot.timing.submit_timestamp, f64(10))
	testing.expect_value(t, slot.timing.host_cpu_seconds, f64(0.01))
	testing.expect_value(t, slot.timing.pacer_wait_seconds, f64(0.002))
	ctx.epoch = 2
	_frame_delivery_submitted(ctx, 1, 20)
	context_frame_delivery_record_host(ctx, 0.03, 0.004)
	testing.expect_value(t, slot.timing.submit_timestamp, f64(10))
	testing.expect_value(t, slot.timing.host_cpu_seconds, f64(0.01))
	testing.expect_value(t, slot.timing.pacer_wait_seconds, f64(0.002))
}

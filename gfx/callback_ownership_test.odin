#+build !js
package gfx

import "core:testing"
import wg "vendor:wgpu"

// These tests drive the registered userdata addresses directly, so every
// callback path runs against the storage the backend would actually reach.
// No device exists here: a nil device makes every bounded poll give up at
// once, which is exactly the permanent-stall case the contract must survive.

@(test)
context_close_refuses_while_timing_registration_armed :: proc(t: ^testing.T) {
	ctx := new(Context)
	defer free(ctx)
	ctx.instance = cast(wg.Instance)uintptr(1)
	ctx.initialized = true
	ctx.lifecycle = .Ready
	ctx.gpu_timing.available = true
	_submission_init(&ctx.submissions, ctx)
	slot := &ctx.gpu_timing.slots[1]
	slot.generation = 3
	slot.submission = 2
	slot.query_count = 2
	record := gpu_timing_test_arm(ctx, 1)
	testing.expect(t, !context_quiesce_gpu(ctx))
	testing.expect(t, !context_close(ctx))
	testing.expect_value(t, ctx.lifecycle, Context_Lifecycle.Closing)
	testing.expect(t, ctx.initialized)
	testing.expect(t, ctx.instance != nil)
	testing.expect(t, ctx.gpu_timing.closing)
	testing.expect_value(t, slot.phase, Gpu_Timing_Phase.Quarantined)
	testing.expect(t, record.armed && !record.done)
	testing.expect(t, ctx.submissions.closing)
	testing.expect(t, !context_close(ctx))
	testing.expect(t, record.armed && !record.done)
	_gpu_timing_map_done(.Aborted, {}, record, nil)
	testing.expect(t, record.done)
	testing.expect(t, _gpu_timing_retire(ctx))
	testing.expect_value(t, ctx.gpu_timing.health.map_failure, u64(1))
	testing.expect(t, !record.armed && !record.done)
	testing.expect(t, context_quiesce_gpu(ctx))
	ctx.instance = nil
}

@(test)
context_quiesce_does_not_close :: proc(t: ^testing.T) {
	ctx := new(Context)
	defer free(ctx)
	ctx.initialized = true
	ctx.lifecycle = .Ready
	ctx.gpu_timing.available = true
	_submission_init(&ctx.submissions, ctx)
	testing.expect(t, context_quiesce_gpu(ctx))
	testing.expect_value(t, ctx.lifecycle, Context_Lifecycle.Ready)
	testing.expect(t, !ctx.gpu_timing.closing)
	testing.expect(t, !ctx.submissions.closing)
	_gpu_timing_frame_begin(ctx)
	testing.expect_value(t, ctx.gpu_timing.active_slot, 0)
	_gpu_timing_frame_abandon(ctx)
}

@(test)
screenshot_stranded_registration_refuses_until_terminal_callback :: proc(t: ^testing.T) {
	ctx := new(Context)
	defer free(ctx)
	ctx.initialized = true
	record := &ctx.screenshot
	_screenshot_map_done(.Success, {}, record, nil)
	testing.expect(t, !record.done)
	testing.expect_value(t, record.stray, u32(1))
	testing.expect(t, _screenshot_retire(ctx, false))
	testing.expect_value(t, ctx.gpu_timing.health.stray_callbacks, u64(1))
	record.armed = true
	testing.expect(t, !_screenshot_retire(ctx, false))
	testing.expect(t, !_screenshot_retire(ctx, true))
	testing.expect(t, !context_quiesce_gpu(ctx))
	testing.expect(t, record.armed)
	_screenshot_map_done(.Aborted, {}, record, nil)
	testing.expect(t, record.done)
	testing.expect_value(t, record.status, wg.MapAsyncStatus.Aborted)
	_screenshot_map_done(.Aborted, {}, record, nil)
	testing.expect_value(t, record.stray, u32(1))
	testing.expect(t, _screenshot_retire(ctx, false))
	testing.expect(t, !record.armed && !record.done)
	testing.expect_value(t, ctx.gpu_timing.health.stray_callbacks, u64(2))
	testing.expect(t, context_quiesce_gpu(ctx))
}

@(test)
submission_stray_callbacks_are_counted :: proc(t: ^testing.T) {
	ctx := new(Context)
	defer free(ctx)
	_submission_init(&ctx.submissions, ctx)
	tracker := &ctx.submissions
	_submission_done(.Success, {}, tracker, rawptr(uintptr(99)))
	testing.expect_value(t, tracker.stray, u32(1))
	ticket := _submission_reserve(tracker)
	testing.expect(t, ticket != 0)
	testing.expect_value(t, ctx.gpu_timing.health.stray_callbacks, u64(1))
	tracker.epoch += 1
	_submission_done(.Success, {}, tracker, rawptr(uintptr(ticket)))
	testing.expect_value(t, tracker.stray, u32(1))
	testing.expect(t, !tracker.tickets[0].complete)
	tracker.epoch -= 1
	_submission_done(.Error, {}, tracker, rawptr(uintptr(ticket)))
	testing.expect(t, tracker.tickets[0].complete)
	testing.expect(t, tracker.tickets[0].failed)
	testing.expect(t, _submission_quiesce(tracker))
	testing.expect_value(t, tracker.count, u32(0))
	testing.expect_value(t, ctx.gpu_timing.health.stray_callbacks, u64(2))
	testing.expect(t, !tracker.closing)
}

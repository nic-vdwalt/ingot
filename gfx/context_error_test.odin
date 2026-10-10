#+build !js
package gfx

import "core:testing"
import wg "vendor:wgpu"

@(test)
context_error_defaults_to_none :: proc(t: ^testing.T) {
	ctx := new(Context)
	defer free(ctx)
	testing.expect(t, context_error(ctx) == .None)
	testing.expect_value(t, ctx.last_error, Context_Error.None)
}

@(test)
context_close_refused_records_close_refused :: proc(t: ^testing.T) {
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
	testing.expect(t, !context_close(ctx))
	testing.expect_value(t, context_error(ctx), Context_Error.Close_Refused)
	testing.expect_value(t, ctx.lifecycle, Context_Lifecycle.Closing)
	_gpu_timing_map_done(.Aborted, {}, record, nil)
	testing.expect(t, _gpu_timing_retire(ctx))
	testing.expect(t, context_quiesce_gpu(ctx))
	ctx.instance = nil
}

@(test)
context_close_of_empty_context_clears_error :: proc(t: ^testing.T) {
	ctx := new(Context)
	defer free(ctx)
	ctx.id = 1
	ctx.last_error = .Swapchain
	testing.expect(t, context_close(ctx))
	testing.expect_value(t, context_error(ctx), Context_Error.None)
	testing.expect_value(t, ctx.id, u32(1))
}

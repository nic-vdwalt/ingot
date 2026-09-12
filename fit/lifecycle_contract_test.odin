#+build !js
package fit

import "core:testing"
import "ingot:gfx"
import "ingot:ui"
import "ingot:ui_gfx"

INGOT_FIT_EXPECTED_ASSERTS :: #config(INGOT_FIT_EXPECTED_ASSERTS, false)

@(test)
fit_configured_session_installs_hooks :: proc(t: ^testing.T) {
	graphics := new(gfx.Context)
	defer free(graphics)
	session := new(ui_gfx.Session)
	defer free(session)
	config := Config {
		session = {
			scale_metrics = contract_scale_metrics,
			scale_invalidate = contract_scale_invalidate,
		},
	}
	for _ in 0 ..< 2 {
		ui_gfx.session_init_context(session, graphics, to_app_config(config).session)
		testing.expect(t, session.runtime.scale_metrics_hook == contract_scale_metrics)
		testing.expect(t, session.runtime.scale_invalidate_hook == contract_scale_invalidate)
		contract_metrics_calls = 0
		contract_invalidation_calls = 0
		ui_gfx.session_set_user_scale(session, 1.5)
		testing.expect(t, contract_metrics_calls > 0)
		testing.expect(t, contract_invalidation_calls > 0)
		ui_gfx.session_destroy(session)
	}
}

@(test)
fit_session_destroy_resets_storage :: proc(t: ^testing.T) {
	session := new(Session)
	defer free(session)
	graphics := new(gfx.Context)
	defer free(graphics)
	nodes: [STORAGE_NODE_DEFAULT + 1]Storage_Node
	outputs: [STORAGE_NODE_DEFAULT + 1]^bool
	for _ in 0 ..< 2 {
		ui_gfx.session_init_context(&session.inner, graphics)
		Set_Storage(&session.builder, {nodes = nodes[:], outputs = outputs[:]})
		testing.expect_value(t, Storage_Capacity(&session.builder), len(nodes))
		Session_Destroy(session)
		testing.expect(t, !session.inner.initialized && !session.builder.bound)
		testing.expect(t, session.draw == nil && session.user_data == nil)
		testing.expect_value(t, Storage_Capacity(&session.builder), int(STORAGE_NODE_DEFAULT))
	}
}

@(private = "file")
contract_metrics_calls: int
@(private = "file")
contract_invalidation_calls: int

@(private = "file")
contract_scale_metrics :: proc(scale: f32) {
	assert(scale > 0)
	contract_metrics_calls += 1
}

@(private = "file")
contract_scale_invalidate :: proc() {
	contract_invalidation_calls += 1
}

@(private = "file")
contract_access_draw :: proc(builder: ^Builder, user_data: rawptr) {
	assert(builder != nil && user_data != nil)
	access := cast(^Debug_Frame_Access)user_data
	access^ = Debug_Frame_Access_Get(builder)
	root := Column(builder)
	Label(root, "Lifecycle")
}

@(test)
fit_frame_access_expires_after_test_driver_frame :: proc(t: ^testing.T) {
	driver: Test_Driver
	Test_Driver_Init(&driver)
	defer Test_Driver_Destroy(&driver)
	access: Debug_Frame_Access
	testing.expect(t, Test_Driver_Frame(&driver, {}, contract_access_draw, &access))
	testing.expect(t, !Debug_Frame_Access_Valid(access))
}

@(test)
fit_async_ticket_completes_once_before_owner_teardown :: proc(t: ^testing.T) {
	builder: Builder
	debug_owner_prepare(&builder)
	ticket, ok := Debug_Async_Begin(&builder)
	testing.expect(t, ok)
	testing.expect_value(t, builder.owner.outstanding, u32(1))
	Debug_Async_Complete(ticket)
	testing.expect_value(t, builder.owner.outstanding, u32(0))
	debug_owner_retire(&builder)
	testing.expect(t, !builder.owner.alive)
}

when ODIN_OS != .Windows || INGOT_FIT_EXPECTED_ASSERTS {
	@(test)
	fit_async_duplicate_completion_is_rejected :: proc(t: ^testing.T) {
		builder: Builder
		debug_owner_prepare(&builder)
		ticket, ok := Debug_Async_Begin(&builder)
		testing.expect(t, ok)
		Debug_Async_Complete(ticket)
		testing.expect_assert_message(t, "Fit.Debug_Async_Complete: duplicate completion")
		Debug_Async_Complete(ticket)
	}

	@(test)
	fit_owner_teardown_with_async_completion_is_rejected :: proc(t: ^testing.T) {
		builder: Builder
		debug_owner_prepare(&builder)
		_, ok := Debug_Async_Begin(&builder)
		testing.expect(t, ok)
		testing.expect_assert_message(t, "fit debug owner: callbacks outstanding")
		debug_owner_retire(&builder)
	}

	@(test)
	fit_async_completion_into_retired_owner_is_rejected :: proc(t: ^testing.T) {
		builder: Builder
		debug_owner_prepare(&builder)
		ticket, ok := Debug_Async_Begin(&builder)
		testing.expect(t, ok)
		builder.owner.outstanding = 0
		debug_owner_retire(&builder)
		testing.expect_assert_message(
			t,
			"Fit.Debug_Async_Complete: completion into destroyed owner",
		)
		Debug_Async_Complete(ticket)
	}

	@(test)
	fit_parent_mutation_outside_build_phase_is_rejected :: proc(t: ^testing.T) {
		frame := ui.Ui_Frame {
			generation = 1,
			phase      = .Measure,
			open       = true,
		}
		builder := Builder {
			generation = 1,
			frame_ticket = {frame = &frame, generation = 1},
			bound = true,
		}
		root := Parent {
			builder    = &builder,
			generation = 1,
			handle     = 0,
			identity   = ui.Widget_Id(1),
		}
		testing.expect_assert_message(t, "Fit.Parent: invalid phase")
		Label(root, "Invalid")
	}
}

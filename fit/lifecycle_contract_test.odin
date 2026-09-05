package fit

import "core:testing"
import "ingot:gfx"
import "ingot:ui_gfx"

@(test)
fit_configured_session_installs_hooks :: proc(t: ^testing.T) {
	graphics := new(gfx.Context)
	defer free(graphics)
	session := new(ui_gfx.Session)
	defer free(session)
	config := Config{session = {
		scale_metrics = contract_scale_metrics,
		scale_invalidate = contract_scale_invalidate,
	}}
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

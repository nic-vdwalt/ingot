#+build !js
package ui_gfx

import "core:testing"
import gfx "ingot:gfx"
import "ingot:ui"

@(test)
app_lifecycle_rejects_invalid_transitions :: proc(t: ^testing.T) {
	app := new(App)
	defer free(app)
	testing.expect(t, !app_start(app))
	testing.expect(t, !app_tick(app))
	testing.expect(t, !app_stop(app))
	app.state = .Stopped
	testing.expect(t, !app_start(app))
	testing.expect(t, !app_stop(app))
}

@(test)
app_explicit_hidden_flag_defers_windows_show :: proc(t: ^testing.T) {
	testing.expect(t, app_show_after_init({}, true))
	testing.expect(t, !app_show_after_init({.WINDOW_HIDDEN}, true))
	testing.expect(t, !app_show_after_init({}, false))
}

@(test)
app_pacing_resolves_explicit_modes :: proc(t: ^testing.T) {
	config := App_Config {
		target_fps = 60,
	}
	testing.expect_value(t, app_resolve_target_fps(config, 144), i32(60))
	config.frame_pacing = .Uncapped
	testing.expect_value(t, app_resolve_target_fps(config, 144), i32(0))
	config.frame_pacing = .Monitor_Refresh
	testing.expect_value(t, app_resolve_target_fps(config, 144), i32(144))
	testing.expect_value(t, app_resolve_target_fps(config, 0), i32(60))
	config.target_fps = 0
	testing.expect_value(t, app_resolve_target_fps(config, 0), i32(0))
}

@(test)
app_screen_rect_reads_owned_context :: proc(t: ^testing.T) {
	app := new(App)
	gfx_context := new(gfx.Context)
	defer free(app)
	defer free(gfx_context)
	gfx_context.width = 640
	gfx_context.height = 360
	app.gfx_context = gfx_context
	app.state = .Ready
	testing.expect_value(t, app_screen_rect(app), ui.Rect_I32{0, 0, 640, 360})
}

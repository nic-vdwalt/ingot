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

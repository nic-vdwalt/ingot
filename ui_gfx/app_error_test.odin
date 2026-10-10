#+build !js
package ui_gfx

import "core:testing"
import gfx "ingot:gfx"

@(test)
app_error_defaults_to_none :: proc(t: ^testing.T) {
	app := new(App)
	defer free(app)
	testing.expect_value(t, app_error(app), App_Error.None)
	testing.expect_value(t, app_graphics_error(app), gfx.Context_Error.None)
}

@(test)
app_start_and_stop_record_invalid_state :: proc(t: ^testing.T) {
	app := new(App)
	defer free(app)
	testing.expect(t, !app_start(app))
	testing.expect_value(t, app_error(app), App_Error.Invalid_State)
	app.last_error = .None
	testing.expect(t, !app_stop(app))
	testing.expect_value(t, app_error(app), App_Error.Invalid_State)
	app.state = .Stopped
	app.last_error = .None
	testing.expect(t, !app_start(app))
	testing.expect_value(t, app_error(app), App_Error.Invalid_State)
}

@(test)
app_start_records_context_not_live :: proc(t: ^testing.T) {
	app := new(App)
	gfx_context := new(gfx.Context)
	defer free(app)
	defer free(gfx_context)
	app.gfx_context = gfx_context
	app.state = .Ready
	testing.expect(t, !app_start(app))
	testing.expect_value(t, app_error(app), App_Error.Context_Not_Live)
	testing.expect_value(t, app.state, App_State.Ready)
}

@(test)
app_graphics_error_reads_owned_context :: proc(t: ^testing.T) {
	app := new(App)
	gfx_context := new(gfx.Context)
	defer free(app)
	defer free(gfx_context)
	app.gfx_context = gfx_context
	gfx_context.last_error = .Adapter
	app.last_error = .Graphics
	testing.expect_value(t, app_error(app), App_Error.Graphics)
	testing.expect_value(t, app_graphics_error(app), gfx.Context_Error.Adapter)
}

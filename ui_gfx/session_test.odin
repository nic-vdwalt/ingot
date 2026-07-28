#+build !js
package ui_gfx

import "core:testing"
import rl "ingot:gfx"
import "ingot:ui"

@(test)
test_session_init_destroy_round_trip :: proc(t: ^testing.T) {
	gfx_context := new(rl.Context)
	defer free(gfx_context)
	session := new(Session)
	defer free(session)
	config := Session_Config {
		user_scale        = 1.25,
		semantics_enabled = false,
	}
	session_init_context(session, gfx_context, config)

	testing.expect(t, session.initialized)
	testing.expect(t, session.runtime.initialized)
	testing.expect(t, session.adapter.initialized)
	testing.expect(t, session.adapter.gfx_context == gfx_context)
	testing.expect_value(t, session.adapter.gfx_epoch, rl.context_epoch(gfx_context))
	testing.expect_value(t, session.adapter.font_dpi, f32(1))
	testing.expect(t, !session.frame_open)
	testing.expect(t, session.gfx_frame == nil)
	testing.expect_value(t, session.config, config)

	session_destroy(session)
	testing.expect(t, !session.initialized)
	testing.expect(t, !session.frame_open)
	testing.expect(t, !session.runtime.initialized)
	testing.expect(t, !session.adapter.initialized)
	testing.expect(t, session.adapter.gfx_context == nil)
	testing.expect(t, session.adapter.gfx_frame == nil)
	testing.expect(t, session.gfx_frame == nil)
}

@(test)
test_session_plain_frame_round_trip :: proc(t: ^testing.T) {
	gfx_context := new(rl.Context)
	defer free(gfx_context)
	session := new(Session)
	defer free(session)
	session_init_context(session, gfx_context)
	defer session_destroy(session)

	for _ in 0 ..< 2 {
		frame := session_begin_frame(session)
		testing.expect(t, frame == &session.frame)
		testing.expect(t, session.frame_open)
		testing.expect(t, session.frame.open)
		testing.expect(t, session.frame.output == &session.output)
		testing.expect(t, session.adapter.gfx_frame == nil)
		testing.expect(t, session.gfx_frame == nil)
		testing.expect(t, session.runtime.text_backend.data == &session.adapter)

		session_end_frame(session)
		testing.expect(t, !session.frame_open)
		testing.expect(t, !session.frame.open)
		testing.expect(t, session.adapter.gfx_frame == nil)
		testing.expect(t, session.gfx_frame == nil)
	}
}

@(test)
test_adapter_font_dpi_normalizes :: proc(t: ^testing.T) {
	gfx_context := new(rl.Context)
	defer free(gfx_context)
	adapter: Adapter
	adapter_init_context(&adapter, gfx_context)
	defer adapter_destroy(&adapter)

	testing.expect_value(t, adapter.font_dpi, f32(1))
	adapter_set_font_dpi(&adapter, 0)
	testing.expect_value(t, adapter.font_dpi, f32(1))
	adapter_set_font_dpi(&adapter, -1)
	testing.expect_value(t, adapter.font_dpi, f32(1))
	adapter_set_font_dpi(&adapter, 2)
	testing.expect_value(t, adapter.font_dpi, f32(2))
	testing.expect_value(t, adapter.font_count, 0)
	adapter_set_font_dpi(&adapter, 1.5)
	testing.expect_value(t, adapter.font_dpi, f32(1.5))
}

@(test)
test_session_frame_captures_context_input :: proc(t: ^testing.T) {
	gfx_context := new(rl.Context)
	defer free(gfx_context)
	gfx_context.width = 640
	gfx_context.height = 480
	gfx_context.dpi = 2
	session := new(Session)
	defer free(session)
	session_init_context(session, gfx_context)
	defer session_destroy(session)

	frame := session_begin_frame(session)
	testing.expect(t, frame == &session.frame)
	testing.expect_value(t, session.input.screen_size, ui.Vec2{640, 480})
	testing.expect_value(t, session.input.dpi_scale, f32(2))
	when ODIN_OS == .Darwin {
		testing.expect_value(t, session.adapter.font_dpi, f32(2))
	} else {
		testing.expect_value(t, session.adapter.font_dpi, f32(1))
	}
	session_end_frame(session)
}

@(test)
test_app_session_compatibility_aliases_compile :: proc(t: ^testing.T) {
	gfx_context := new(rl.Context)
	defer free(gfx_context)
	session := new(App_Session)
	defer free(session)
	config := App_Session_Config{semantics_enabled = false}
	app_session_init_context(session, gfx_context, config)
	frame := app_session_begin_frame(session)
	testing.expect(t, frame == &session.frame)
	app_session_end_frame(session)
	app_session_destroy(session)
	testing.expect(t, !session.initialized)
}

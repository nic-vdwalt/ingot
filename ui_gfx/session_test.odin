#+build !js
package ui_gfx

import "core:sync"
import "core:testing"
import rl "ingot:gfx"
import "ingot:ui"

test_context_mutex: sync.Mutex

test_context_lock :: proc() {
	sync.mutex_lock(&test_context_mutex)
}

test_context_unlock :: proc() {
	sync.mutex_unlock(&test_context_mutex)
}

@(test)
test_session_init_destroy_round_trip :: proc(t: ^testing.T) {
	test_context_lock()
	defer test_context_unlock()
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
	testing.expect(t, !session.graphics_open)
	testing.expect_value(t, session.config, config)

	testing.expect(t, !session.adapter.a11y_initialized)
	session_destroy(session)
	testing.expect(t, !session.initialized)
	testing.expect(t, !session.frame_open)
	testing.expect(t, !session.runtime.initialized)
	testing.expect(t, !session.adapter.initialized)
	testing.expect(t, session.adapter.gfx_context == nil)
	testing.expect(t, !session.adapter.graphics_open)
}

@(test)
test_session_plain_frame_round_trip :: proc(t: ^testing.T) {
	test_context_lock()
	defer test_context_unlock()
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
		testing.expect(t, !session.adapter.graphics_open)
		testing.expect(t, !session.graphics_open)
		testing.expect(t, session.runtime.text_backend.data == &session.adapter)
		testing.expect(t, session.output.main.sink == nil)
		ui.paint_push(&session.output.main, {kind = .Rectangle})
		ui.paint_push(&session.output.overlay, {kind = .Rectangle})

		session_end_frame(session)
		testing.expect(t, !session.frame_open)
		testing.expect(t, !session.frame.open)
		testing.expect(t, !session.adapter.graphics_open)
		testing.expect(t, !session.graphics_open)
	}
}

@(test)
test_session_scale_applies_immediately_outside_frame :: proc(t: ^testing.T) {
	test_context_lock()
	defer test_context_unlock()
	gfx_context := new(rl.Context)
	defer free(gfx_context)
	session := new(Session)
	defer free(session)
	session_init_context(session, gfx_context)
	defer session_destroy(session)

	session_set_user_scale(session, 1.5)
	testing.expect_value(t, session.config.user_scale, f32(1.5))
	testing.expect_value(t, session.runtime.scale, f32(1.5))
	testing.expect(t, !session.pending_scale)
}

@(test)
test_session_scale_defers_until_next_frame :: proc(t: ^testing.T) {
	test_context_lock()
	defer test_context_unlock()
	gfx_context := new(rl.Context)
	defer free(gfx_context)
	session := new(Session)
	defer free(session)
	session_init_context(session, gfx_context)
	defer session_destroy(session)

	_ = session_begin_frame(session)
	active_scale := session.runtime.scale
	active_font_epoch := session.runtime.font_epoch
	session_set_user_scale(session, 1.5)
	testing.expect_value(t, session.config.user_scale, f32(1.5))
	testing.expect_value(t, session.runtime.scale, active_scale)
	testing.expect_value(t, session.runtime.font_epoch, active_font_epoch)
	testing.expect(t, session.pending_scale)
	session_end_frame(session)

	_ = session_begin_frame(session)
	testing.expect_value(t, session.runtime.scale, f32(1.5))
	testing.expect(t, session.runtime.font_epoch > active_font_epoch)
	testing.expect(t, !session.pending_scale)
	session_end_frame(session)
}

@(test)
test_session_draw_api_compiles :: proc(t: ^testing.T) {
	draw: proc(session: ^Session, callback: Session_Draw_Proc, userdata: rawptr) -> bool =
		session_draw
	callback: Session_Draw_Proc = test_session_draw_callback

	testing.expect(t, draw != nil)
	testing.expect(t, callback != nil)
}

@(private = "file")
test_session_draw_callback :: proc(session: ^Session, frame: ^ui.Ui_Frame, userdata: rawptr) {
	assert(session != nil && frame != nil, "test_session_draw_callback: invalid frame")
	_ = userdata
}

@(test)
test_adapter_font_dpi_normalizes :: proc(t: ^testing.T) {
	test_context_lock()
	defer test_context_unlock()
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
	test_context_lock()
	defer test_context_unlock()
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
test_pointer_snapshot_policy :: proc(t: ^testing.T) {
	focused := ui.Ui_Input {
		mouse_position   = {40, 24},
		mouse_delta      = {3, -2},
		mouse_wheel      = {0, 1},
		window_focused   = true,
		cursor_on_screen = true,
	}
	focused.mouse_pressed[0] = true
	focused.mouse_released[1] = true
	focused.mouse_down[2] = true
	pointer_snapshot_sanitize(&focused)
	testing.expect_value(t, focused.mouse_position, ui.Vec2{40, 24})
	testing.expect_value(t, focused.mouse_delta, ui.Vec2{3, -2})
	testing.expect_value(t, focused.mouse_wheel, ui.Vec2{0, 1})
	testing.expect(t, focused.mouse_pressed[0])
	testing.expect(t, focused.mouse_released[1])
	testing.expect(t, focused.mouse_down[2])

	unfocused := focused
	unfocused.window_focused = false
	pointer_snapshot_sanitize(&unfocused)
	testing.expect(t, !unfocused.window_focused)
	testing.expect(t, !unfocused.cursor_on_screen)
	testing.expect_value(t, unfocused.mouse_position, ui.Vec2{-1, -1})
	testing.expect_value(t, unfocused.mouse_delta, ui.Vec2{})
	testing.expect_value(t, unfocused.mouse_wheel, ui.Vec2{})
	testing.expect(t, !unfocused.mouse_pressed[0])
	testing.expect(t, !unfocused.mouse_released[1])
	testing.expect(t, !unfocused.mouse_down[2])

	outside := focused
	outside.cursor_on_screen = false
	pointer_snapshot_sanitize(&outside)
	testing.expect(t, outside.window_focused)
	testing.expect(t, !outside.cursor_on_screen)
	testing.expect_value(t, outside.mouse_position, ui.Vec2{-1, -1})
	testing.expect_value(t, outside.mouse_delta, ui.Vec2{})
	testing.expect_value(t, outside.mouse_wheel, ui.Vec2{})
	testing.expect(t, !outside.mouse_pressed[0])
	testing.expect(t, !outside.mouse_released[1])
	testing.expect(t, !outside.mouse_down[2])
}

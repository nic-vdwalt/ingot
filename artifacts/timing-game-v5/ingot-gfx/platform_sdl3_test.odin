#+build !js
package gfx

@(require) import "core:testing"
@(require) import sdl "vendor:sdl3"

when INGOT_GFX_SDL3 {

	@(test)
	test_sdl_key_translation :: proc(t: ^testing.T) {
		cases := [?]struct {
			scancode: sdl.Scancode,
			key:      KeyboardKey,
		} {
			{.A, .A},
			{.Z, .Z},
			{._0, .ZERO},
			{._1, .ONE},
			{._9, .NINE},
			{.RETURN, .ENTER},
			{.F1, .F1},
			{.F12, .F12},
			{.KP_0, .KP_0},
			{.KP_9, .KP_9},
			{.LSHIFT, .LEFT_SHIFT},
			{.RGUI, .RIGHT_SUPER},
			{.APPLICATION, .KB_MENU},
			{.UNKNOWN, .KEY_NULL},
		}
		for item in cases {
			testing.expect_value(t, _sdl_key(item.scancode), item.key)
		}
	}

	@(test)
	test_sdl_mouse_button_translation :: proc(t: ^testing.T) {
		testing.expect_value(t, _sdl_mouse_button(sdl.BUTTON_LEFT), i32(MouseButton.LEFT))
		testing.expect_value(t, _sdl_mouse_button(sdl.BUTTON_RIGHT), i32(MouseButton.RIGHT))
		testing.expect_value(t, _sdl_mouse_button(sdl.BUTTON_MIDDLE), i32(MouseButton.MIDDLE))
		testing.expect_value(t, _sdl_mouse_button(sdl.BUTTON_X1), i32(MouseButton.SIDE))
		testing.expect_value(t, _sdl_mouse_button(sdl.BUTTON_X2), i32(MouseButton.EXTRA))
		testing.expect_value(t, _sdl_mouse_button(0), i32(-1))
	}

	@(test)
	test_sdl_cursor_translation :: proc(t: ^testing.T) {
		testing.expect_value(t, _sdl_cursor_kind(.DEFAULT), sdl.SystemCursor.DEFAULT)
		testing.expect_value(t, _sdl_cursor_kind(.ARROW), sdl.SystemCursor.DEFAULT)
		testing.expect_value(t, _sdl_cursor_kind(.IBEAM), sdl.SystemCursor.TEXT)
		testing.expect_value(t, _sdl_cursor_kind(.POINTING_HAND), sdl.SystemCursor.POINTER)
		testing.expect_value(t, _sdl_cursor_kind(.RESIZE_ALL), sdl.SystemCursor.MOVE)
		testing.expect_value(t, _sdl_cursor_kind(.NOT_ALLOWED), sdl.SystemCursor.NOT_ALLOWED)
	}

	@(test)
	test_sdl_axis_normalization :: proc(t: ^testing.T) {
		testing.expect_value(t, _sdl_axis_normalize(-32768), f32(-1))
		testing.expect_value(t, _sdl_axis_normalize(0), f32(0))
		testing.expect_value(t, _sdl_axis_normalize(32767), f32(1))
		testing.expect_value(t, _sdl_trigger_normalize(0), f32(-1))
		testing.expect_value(t, _sdl_trigger_normalize(32767), f32(1))
	}

}

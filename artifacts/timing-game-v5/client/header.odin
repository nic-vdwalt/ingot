// header.odin renders the window's title strip on platforms where ingot
// replaces the native frame (Windows only today: fit.Titlebar_Enabled is
// false everywhere else, so macOS and Linux keep their system title bar and
// this file draws nothing).
//
// The strip auto-hides. It is always up on the menu and loading screens, and
// while playing it appears when the pointer approaches the top edge; the rest
// of the time only the three caption buttons sit in the top-right corner.
// That distinction matters for input, not just for looks: the whole strip is
// published as a window-drag region, so leaving it up permanently would turn
// the top band of the game canvas into a window drag and break camera panning
// there. While hidden, the drag region shrinks to the caption buttons.
package main

import fit "ingot:fit"
import rl "ingot:gfx"

HEADER_TITLE :: "TerraForger"
// Above fit.Z_POPUP (200), which the console panel claims, so the caption
// buttons stay clickable with the console open.
HEADER_Z :: fit.Z_Order(300)
// The pointer must climb back past this multiple of the strip height before
// the strip hides again. Without the gap the strip flickers whenever the
// pointer rests on the boundary, because hiding it moves the content that
// the pointer is over.
HEADER_HIDE_BAND :: i32(2)

// header_height is the strip height. fit's tab bar metric is already scaled
// for the monitor DPI, so it needs no ui_px conversion.
header_height :: proc(surface: ^fit.Surface) -> i32 {
	assert(surface != nil, "header_height: nil surface")
	return fit.Get_Metrics(surface).tab_bar_height
}

// header_inset is the vertical space the HUD must leave clear. It uses the
// full strip height rather than the current reveal state, so HUD text does
// not jump every time the strip slides in or out.
header_inset :: proc(value: ^Client_State, surface: ^fit.Surface) -> i32 {
	assert(value != nil, "header_inset: nil state")
	assert(surface != nil, "header_inset: nil surface")
	if !fit.Titlebar_Enabled() do return 0
	return header_height(surface)
}

// header_revealed latches whether the full strip is drawn this frame, and
// returns the new state. Split from header_frame so the reveal rules are
// testable without a live surface.
//
// caption_active is true while a caption button is hovered or pressed: those
// are non-client, so raylib reports no pointer over them and the strip would
// otherwise vanish under the cursor mid-click.
header_revealed :: proc(
	value: ^Client_State,
	header_h, mouse_y: i32,
	caption_active: bool,
) -> bool {
	assert(value != nil, "header_revealed: nil state")
	assert(header_h > 0, "header_revealed: non-positive header height")
	// The menu and both loading screens have no camera to fight over, and a
	// bare set of caption buttons floating on an empty screen reads as a
	// rendering bug rather than a design.
	if value.screen != .Playing || caption_active {
		value.header_shown = true
		return true
	}
	// An in-flight drag owns the pointer. Revealing the strip mid-drag would
	// slide a window-drag region under a camera pan or a terraform sculpt.
	if value.press_active || value.sculpt_active || value.grab_pan.active {
		value.header_shown = false
		return false
	}
	if mouse_y < header_h {
		value.header_shown = true
	} else if mouse_y >= header_h * HEADER_HIDE_BAND {
		value.header_shown = false
	}
	return value.header_shown
}

// header_frame draws the strip (or just the caption buttons) and publishes
// the non-client hit-test layout. Call last in the frame so it paints over
// every other layer.
header_frame :: proc(value: ^Client_State, surface: ^fit.Surface) {
	assert(value != nil, "header_frame: nil state")
	assert(surface != nil, "header_frame: nil surface")
	if !fit.Titlebar_Enabled() do return
	screen_width := rl.GetScreenWidth()
	if screen_width <= 0 do return
	header_h := header_height(surface)
	if header_h <= 0 do return
	hover, pressed, maximized := fit.Titlebar_State()
	mouse := fit.Mouse_Position(surface)
	revealed := header_revealed(value, header_h, i32(mouse.y), hover != .None || pressed != .None)
	claim := fit.Float_Rect{0, 0, f32(screen_width), f32(header_h)}
	fit.Layer_Begin(surface, HEADER_Z, claim)
	defer fit.Layer_End(surface)
	if revealed {
		// Surface_App_Header publishes interactive_right = 0 itself, making
		// the whole strip minus the buttons a drag region.
		_ = fit.Surface_App_Header(surface, HEADER_TITLE, screen_width)
		return
	}
	minimize, maximize, close := fit.Surface_Caption_Buttons(
		surface,
		screen_width,
		{hover = hover, pressed = pressed, maximized = maximized},
	)
	// interactive_right = screen_width: everything in the caption band except
	// the three buttons stays client area, so the canvas keeps its input.
	fit.Titlebar_Set_Layout(minimize, maximize, close, screen_width, header_h)
}

// header_contains is the pointer-capture test. It runs before header_frame in
// the frame, so it reads the previous frame's reveal latch; the difference is
// one frame of a strip the pointer is only just entering.
header_contains :: proc(value: ^Client_State, surface: ^fit.Surface, point: rl.Vector2) -> bool {
	assert(value != nil, "header_contains: nil state")
	assert(surface != nil, "header_contains: nil surface")
	if !fit.Titlebar_Enabled() do return false
	header_h := header_height(surface)
	y := i32(point.y)
	if y < 0 || y >= header_h do return false
	if value.header_shown do return true
	x := i32(point.x)
	return x >= rl.GetScreenWidth() - fit.Surface_Caption_Buttons_Width(surface)
}

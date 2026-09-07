package main

import "core:testing"

HEADER_TEST_HEIGHT :: i32(35)

// Hysteresis: the strip appears at the top edge and only hides once the
// pointer has clearly left it, so it cannot flicker on the boundary.
@(test)
header_reveal_uses_hysteresis :: proc(t: ^testing.T) {
	value := new(Client_State)
	defer free(value)
	value.screen = .Playing
	testing.expect(
		t,
		!header_revealed(value, HEADER_TEST_HEIGHT, HEADER_TEST_HEIGHT + 1, false),
		"mid-canvas pointer must not reveal the strip",
	)
	testing.expect(
		t,
		header_revealed(value, HEADER_TEST_HEIGHT, HEADER_TEST_HEIGHT - 1, false),
		"pointer at the top edge must reveal the strip",
	)
	testing.expect(
		t,
		header_revealed(value, HEADER_TEST_HEIGHT, HEADER_TEST_HEIGHT + 1, false),
		"the strip must stay up inside the hysteresis band",
	)
	testing.expect(
		t,
		!header_revealed(value, HEADER_TEST_HEIGHT, HEADER_TEST_HEIGHT * 2 + 1, false),
		"the strip must hide once the pointer clears the band",
	)
}

// Caption buttons are non-client, so raylib reports no pointer over them. The
// strip has to stay up while one is hovered or the button vanishes from under
// the cursor mid-click.
@(test)
header_stays_revealed_for_caption_buttons :: proc(t: ^testing.T) {
	value := new(Client_State)
	defer free(value)
	value.screen = .Playing
	testing.expect(
		t,
		header_revealed(value, HEADER_TEST_HEIGHT, 400, true),
		"a hovered caption button must hold the strip open",
	)
}

// A drag owns the pointer: sliding a window-drag region under a camera pan or
// a terraform sculpt would hand the drag to the window manager.
@(test)
header_hides_during_pointer_drags :: proc(t: ^testing.T) {
	drags := []struct {
		name:  string,
		apply: proc(value: ^Client_State),
	} {
		{"press", proc(value: ^Client_State) {value.press_active = true}},
		{"sculpt", proc(value: ^Client_State) {value.sculpt_active = true}},
		{"grab pan", proc(value: ^Client_State) {value.grab_pan.active = true}},
	}
	for drag in drags {
		value := new(Client_State)
		defer free(value)
		value.screen = .Playing
		value.header_shown = true
		drag.apply(value)
		testing.expectf(
			t,
			!header_revealed(value, HEADER_TEST_HEIGHT, 0, false),
			"the strip must hide during a %s drag",
			drag.name,
		)
	}
}

// Off the playing screen there is no camera to fight over, and floating
// caption buttons on an otherwise empty screen read as a rendering fault.
@(test)
header_is_always_revealed_off_the_playing_screen :: proc(t: ^testing.T) {
	for screen in Screen {
		if screen == .Playing do continue
		value := new(Client_State)
		defer free(value)
		value.screen = screen
		testing.expectf(
			t,
			header_revealed(value, HEADER_TEST_HEIGHT, 500, false),
			"the strip must stay up on the %v screen",
			screen,
		)
	}
}

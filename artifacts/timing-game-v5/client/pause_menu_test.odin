package main

import ecs "ingot:ecs"
import "core:testing"

// Escape from a clean inspect state has nothing to cancel, so it opens the
// menu. This is the case the whole precedence exists to protect: it must not
// fire while the player is still in a mode.
@(test)
pause_escape_opens_the_menu_from_a_clean_state :: proc(t: ^testing.T) {
	testing.expect_value(t, pause_escape_action(false, .Root, false), Pause_Escape.Open_Menu)
}

// Build and terraform mode, and a live selection, all consume Escape first -
// the behaviour the toolbar's "Inspect (Esc)" label promises.
@(test)
pause_escape_cancels_a_live_context_before_opening :: proc(t: ^testing.T) {
	testing.expect_value(
		t,
		pause_escape_action(false, .Root, true),
		Pause_Escape.Cancel_Context,
	)
	// The page is irrelevant while the menu is closed; a stale page must not
	// change what Escape does in the world.
	for page in Pause_Page {
		testing.expectf(
			t,
			pause_escape_action(false, page, true) == .Cancel_Context,
			"a closed menu on page %v must still cancel the context",
			page,
		)
	}
}

// Escape on a sub-page backs out one level rather than closing outright, so
// a mistimed press cannot drop the player straight back into the world from
// the exit confirmation.
@(test)
pause_escape_backs_out_of_sub_pages :: proc(t: ^testing.T) {
	testing.expect_value(t, pause_escape_action(true, .Settings, false), Pause_Escape.Back_To_Root)
	testing.expect_value(
		t,
		pause_escape_action(true, .Confirm_Exit, false),
		Pause_Escape.Back_To_Root,
	)
	// A context behind the menu does not change this: the menu is on top and
	// owns the key while it is open.
	testing.expect_value(t, pause_escape_action(true, .Settings, true), Pause_Escape.Back_To_Root)
}

@(test)
pause_escape_closes_the_root_page :: proc(t: ^testing.T) {
	testing.expect_value(t, pause_escape_action(true, .Root, false), Pause_Escape.Close_Menu)
	testing.expect_value(t, pause_escape_action(true, .Root, true), Pause_Escape.Close_Menu)
}

// pause_context_active is what feeds has_context; it has to agree with the
// two things Escape used to clear.
@(test)
pause_context_tracks_mode_and_selection :: proc(t: ^testing.T) {
	value := new(Client_State)
	defer free(value)
	testing.expect(t, !pause_context_active(value), "a neutral inspect state has no context")
	value.mode = .Build
	testing.expect(t, pause_context_active(value), "build mode is a live context")
	value.mode = .Terraform
	testing.expect(t, pause_context_active(value), "terraform mode is a live context")
	value.mode = .Inspect
	value.selected = ecs.Entity{index = 1, generation = 1}
	testing.expect(t, pause_context_active(value), "a selection is a live context")
}

// A scaled-up panel on a small window must stay on screen. On macOS the UI
// scale is always 1.0, so this overflow is invisible without the test.
@(test)
pause_menu_layout_stays_inside_a_small_viewport :: proc(t: ^testing.T) {
	for page in Pause_Page {
		rows := pause_menu_rows(page)
		rect := pause_menu_layout(2, 640, 480, rows)
		testing.expectf(t, rect.x >= 0 && rect.y >= 0, "panel must not start off screen on %v", page)
		testing.expectf(t, rect.x + rect.w <= 640, "panel must fit the width on %v", page)
		testing.expectf(t, rect.y + rect.h <= 480, "panel must fit the height on %v", page)
	}
}

@(test)
pause_menu_layout_centres_the_panel :: proc(t: ^testing.T) {
	rect := pause_menu_layout(1, 1280, 720, pause_menu_rows(.Root))
	testing.expect_value(t, rect.w, PAUSE_PANEL_WIDTH)
	testing.expect_value(t, rect.x, (1280 - PAUSE_PANEL_WIDTH) / 2)
	testing.expect_value(t, rect.y, (720 - rect.h) / 2)
	testing.expect(t, rect.h > PAUSE_HEADER_HEIGHT, "the panel must reserve room below the header")
}

// The panel has to grow with the UI scale for the same reason the toolbar
// does: fit's fonts and widget metrics grow, raw pixel constants do not.
@(test)
pause_menu_layout_grows_with_ui_scale :: proc(t: ^testing.T) {
	rows := pause_menu_rows(.Settings)
	unit := pause_menu_layout(1, 1920, 1080, rows)
	scaled := pause_menu_layout(1.5, 1920, 1080, rows)
	testing.expect(t, scaled.w > unit.w, "panel must widen with the UI scale")
	testing.expect(t, scaled.h > unit.h, "panel must grow taller with the UI scale")
}

// Every page reserves height for exactly the rows it draws; a page that
// under-reserves paints its last button onto the game canvas.
@(test)
pause_menu_layout_fits_every_row :: proc(t: ^testing.T) {
	for page in Pause_Page {
		rows := pause_menu_rows(page)
		testing.expectf(t, rows > 0, "page %v must have rows", page)
		rect := pause_menu_layout(1, 1920, 1080, rows)
		needed :=
			PAUSE_HEADER_HEIGHT + rows * PAUSE_ROW_HEIGHT + (rows - 1) * PAUSE_ROW_GAP + PAUSE_PADDING
		testing.expectf(t, rect.h >= needed, "page %v must reserve room for its rows", page)
	}
}

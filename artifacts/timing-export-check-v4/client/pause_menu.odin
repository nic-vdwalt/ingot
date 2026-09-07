// pause_menu.odin is the in-world Escape menu: resume, settings, exit.
//
// It is a modal over the running world rather than a return to the title
// screen, so the game keeps rendering and streaming behind it while the sim
// stands still. That is the read the player expects from a pause: the world
// is still there, it just stopped moving.
//
// Escape is overloaded in this client - it already backs out of build and
// terraform mode, and clears the selection - so pause_escape_action owns the
// whole precedence in one pure procedure. Spreading those cases across the
// input handler is how a menu ends up opening on the same keypress that was
// meant to cancel a placement.
//
// Layout constants are authored at UI scale 1.0 and converted through ui_px
// at the point of use, and every colour comes from a fit.Ink or the theme
// tokens (see theme.odin).
package main

import ecs "ingot:ecs"
import fit "ingot:fit"
import rl "ingot:gfx"

// Pause_Page is the menu's current card. Settings and Confirm_Exit are pages
// rather than separate menus so Escape has one meaning on both: go back.
Pause_Page :: enum u8 {
	Root,
	Settings,
	Confirm_Exit,
}

Pause_Menu :: struct {
	open: bool,
	page: Pause_Page,
}

// Pause_Escape is what one Escape press means given the current state. The
// enum exists so the decision is a value the tests can assert on rather than
// a sequence of mutations buried in an input handler.
Pause_Escape :: enum u8 {
	Open_Menu,
	Close_Menu,
	Back_To_Root,
	Cancel_Context,
}

PAUSE_TITLE :: "SYSTEM PAUSED"
PAUSE_HINT :: "ESC RESUMES · WORLD STATE HELD"
PAUSE_SETTINGS_TITLE :: "SETTINGS"
PAUSE_SETTINGS_HINT :: "CHANGES SAVE IMMEDIATELY"
PAUSE_CONFIRM_TITLE :: "EXIT GAME"
PAUSE_CONFIRM_HINT :: "THE ISLAND IS NOT SAVED"

PAUSE_PANEL_WIDTH :: i32(340)
PAUSE_ROW_HEIGHT :: i32(44)
PAUSE_ROW_GAP :: i32(10)
PAUSE_PADDING :: i32(20)
// Space above the first row: the title baseline plus the hint line below it.
PAUSE_HEADER_HEIGHT :: i32(74)
// Gap between the title and the hint line under it.
PAUSE_HINT_OFFSET :: i32(34)

// pause_menu_rows is the row count each page lays out. The layout is sized
// from this rather than from the drawing code so the panel height and the
// hit test cannot disagree about how tall the menu is.
pause_menu_rows :: proc(page: Pause_Page) -> i32 {
	switch page {
	case .Root:
		return 3
	case .Settings:
		return 4
	case .Confirm_Exit:
		return 2
	}
	return 0
}

// pause_escape_action resolves one Escape press.
//
// Pure, and deliberately free of Client_State: the state is 183 MB, so a
// test that needed one to check a keybinding would have to heap-allocate the
// whole world (this is the same reasoning terraform_brush_clamp follows).
//
// The order is the point. A sub-page backs out to the root before the root
// closes, and a live build/terraform context or a selection is cancelled
// before the menu ever opens - which is what keeps the toolbar's
// "Inspect (Esc)" label honest.
pause_escape_action :: proc(open: bool, page: Pause_Page, has_context: bool) -> Pause_Escape {
	if open {
		return .Close_Menu if page == .Root else .Back_To_Root
	}
	return .Cancel_Context if has_context else .Open_Menu
}

// pause_context_active reports whether Escape has something to cancel: a
// non-neutral mode, or a selected building whose panel is showing.
pause_context_active :: proc(value: ^Client_State) -> bool {
	assert(value != nil, "pause_context_active: nil state")
	if value.mode != .Inspect do return true
	return value.selected != ecs.ENTITY_NIL
}

// pause_menu_layout centres the panel for a given row count. Pure so the
// clamp can be tested at a Windows DPI factor from a Mac, where the real
// scale is always 1.0 and the overflow is invisible.
pause_menu_layout :: proc(scale: f32, screen_width, screen_height, rows: i32) -> fit.Rect {
	assert(rows >= 0, "pause_menu_layout: negative row count")
	padding := ui_px(scale, PAUSE_PADDING)
	row_height := ui_px(scale, PAUSE_ROW_HEIGHT)
	gap := ui_px(scale, PAUSE_ROW_GAP)
	width := ui_px(scale, PAUSE_PANEL_WIDTH)
	height := ui_px(scale, PAUSE_HEADER_HEIGHT) + padding + rows * row_height
	if rows > 1 do height += (rows - 1) * gap
	// A scaled-up panel can be taller or wider than a small window; clamping
	// keeps it on screen instead of hanging off both edges.
	width = min(width, max(screen_width, 0))
	height = min(height, max(screen_height, 0))
	x := max((screen_width - width) / 2, 0)
	y := max((screen_height - height) / 2, 0)
	return fit.Rect{x, y, width, height}
}

// pause_menu_rect is the panel bounds for the page currently showing.
pause_menu_rect :: proc(value: ^Client_State) -> fit.Rect {
	assert(value != nil, "pause_menu_rect: nil state")
	return pause_menu_layout(
		value.ui_scale,
		rl.GetScreenWidth(),
		rl.GetScreenHeight(),
		pause_menu_rows(value.pause.page),
	)
}

// pause_menu_contains reports whether a point lands on the panel. The menu
// captures the whole viewport anyway (a click on the scrim must not reach
// the world), so this exists for callers that need the panel proper.
pause_menu_contains :: proc(value: ^Client_State, point: rl.Vector2) -> bool {
	assert(value != nil, "pause_menu_contains: nil state")
	if !value.pause.open do return false
	rect := pause_menu_rect(value)
	x := i32(point.x)
	y := i32(point.y)
	return x >= rect.x && x < rect.x + rect.w && y >= rect.y && y < rect.y + rect.h
}

// pause_menu_open shows the menu at its root page. Opening always resets the
// page: returning to a half-completed exit confirmation would be a prompt the
// player never asked for.
pause_menu_open :: proc(value: ^Client_State) {
	assert(value != nil, "pause_menu_open: nil state")
	value.pause.open = true
	value.pause.page = .Root
	value.status = "paused"
}

pause_menu_close :: proc(value: ^Client_State) {
	assert(value != nil, "pause_menu_close: nil state")
	value.pause.open = false
	value.pause.page = .Root
	value.status = "resumed"
}

// pause_menu_input applies one Escape press. The key is read exactly once
// per frame here, so no other handler can consume or double-handle it.
pause_menu_input :: proc(value: ^Client_State) {
	assert(value != nil, "pause_menu_input: nil state")
	if !rl.IsKeyPressed(.ESCAPE) do return
	action := pause_escape_action(
		value.pause.open,
		value.pause.page,
		pause_context_active(value),
	)
	switch action {
	case .Open_Menu:
		pause_menu_open(value)
	case .Close_Menu:
		pause_menu_close(value)
	case .Back_To_Root:
		value.pause.page = .Root
	case .Cancel_Context:
		value.selected = ecs.ENTITY_NIL
		if value.mode != .Inspect do mode_set(value, .Inspect)
	}
}

// pause_menu_frame draws the scrim and the panel. Runs in screen space after
// the world target has been composited and after the HUD panels, so the
// menu covers them; the console still draws on top of it.
pause_menu_frame :: proc(value: ^Client_State, surface: ^fit.Surface) {
	assert(value != nil, "pause_menu_frame: nil state")
	assert(surface != nil, "pause_menu_frame: nil surface")
	if !value.pause.open do return
	viewport := fit.Viewport(surface)
	fit.Fill_Rect(surface, viewport, fit.Color(UI_MODAL_DIM))
	rect := pause_menu_rect(value)
	panel := fit.Float_Rect{f32(rect.x), f32(rect.y), f32(rect.w), f32(rect.h)}
	ui_panel_draw(value, surface, panel, .Modal)
	title, hint := _pause_page_copy(value.pause.page)
	padding := ui_px(value.ui_scale, PAUSE_PADDING)
	center_x := rect.x + rect.w / 2
	title_y := rect.y + padding
	fit.Text(
		surface,
		title,
		center_x - fit.Text_Width(surface, title, .Title) / 2,
		title_y,
		.Title,
		.Heading,
	)
	fit.Text(
		surface,
		hint,
		center_x - fit.Text_Width(surface, hint, .Note) / 2,
		title_y + ui_px(value.ui_scale, PAUSE_HINT_OFFSET),
		.Note,
		// The exit confirmation is the one page asking the player to weigh
		// a loss, so its hint takes the amber channel.
		.Tool if value.pause.page == .Confirm_Exit else .Label,
	)
	row_x := rect.x + padding
	row_width := max(rect.w - padding * 2, 0)
	row_y := rect.y + ui_px(value.ui_scale, PAUSE_HEADER_HEIGHT)
	switch value.pause.page {
	case .Root:
		_pause_root(value, surface, row_x, row_y, row_width)
	case .Settings:
		_pause_settings(value, surface, row_x, row_y, row_width)
	case .Confirm_Exit:
		_pause_confirm(value, surface, row_x, row_y, row_width)
	}
}

// _pause_page_copy pairs each page with its heading and its hint line.
@(private = "file")
_pause_page_copy :: proc(page: Pause_Page) -> (title: string, hint: string) {
	switch page {
	case .Root:
		return PAUSE_TITLE, PAUSE_HINT
	case .Settings:
		return PAUSE_SETTINGS_TITLE, PAUSE_SETTINGS_HINT
	case .Confirm_Exit:
		return PAUSE_CONFIRM_TITLE, PAUSE_CONFIRM_HINT
	}
	return PAUSE_TITLE, PAUSE_HINT
}

// _pause_row_advance is the y step between rows, shared by every page so the
// cards cannot drift apart from the height pause_menu_layout reserved.
@(private = "file")
_pause_row_advance :: proc(value: ^Client_State) -> i32 {
	return ui_px(value.ui_scale, PAUSE_ROW_HEIGHT) + ui_px(value.ui_scale, PAUSE_ROW_GAP)
}

@(private = "file")
_pause_root :: proc(value: ^Client_State, surface: ^fit.Surface, x, y, width: i32) {
	height := ui_px(value.ui_scale, PAUSE_ROW_HEIGHT)
	advance := _pause_row_advance(value)
	row := y
	if fit.Surface_Button(
		surface,
		fit.Widget_Id_From_String("pause.resume"),
		"RESUME",
		fit.Rect{x, row, width, height},
		.Primary,
	) {
		pause_menu_close(value)
	}
	row += advance
	if fit.Surface_Button(
		surface,
		fit.Widget_Id_From_String("pause.settings"),
		"SETTINGS",
		fit.Rect{x, row, width, height},
		.Secondary,
	) {
		value.pause.page = .Settings
	}
	row += advance
	if fit.Surface_Button(
		surface,
		fit.Widget_Id_From_String("pause.exit"),
		"EXIT GAME",
		fit.Rect{x, row, width, height},
		.Danger,
	) {
		value.pause.page = .Confirm_Exit
	}
}

// _pause_settings exposes the three toggles the prefs file already carries,
// so the console commands and this menu drive exactly the same state. Each
// change writes prefs immediately: a pause menu that lost its settings when
// the player quit from it would be the one place they are most likely to.
@(private = "file")
_pause_settings :: proc(value: ^Client_State, surface: ^fit.Surface, x, y, width: i32) {
	height := ui_px(value.ui_scale, PAUSE_ROW_HEIGHT)
	advance := _pause_row_advance(value)
	row := y
	if fit.Surface_Checkbox(
		surface,
		fit.Widget_Id_From_String("pause.hud"),
		"HUD READOUTS",
		&value.show_hud_text,
		fit.Rect{x, row, width, height},
	) {
		settings_save(value)
	}
	row += advance
	if fit.Surface_Checkbox(
		surface,
		fit.Widget_Id_From_String("pause.fps"),
		"FPS COUNTER",
		&value.show_fps,
		fit.Rect{x, row, width, height},
	) {
		settings_save(value)
	}
	row += advance
	if fit.Surface_Checkbox(
		surface,
		fit.Widget_Id_From_String("pause.profile"),
		"PROFILE OVERLAY",
		&value.profiler.visible,
		fit.Rect{x, row, width, height},
	) {
		settings_save(value)
	}
	row += advance
	if fit.Surface_Button(
		surface,
		fit.Widget_Id_From_String("pause.settings.back"),
		"BACK",
		fit.Rect{x, row, width, height},
		.Secondary,
	) {
		value.pause.page = .Root
	}
}

// _pause_confirm is the second step of the exit. There is no save, so the
// destructive action is never one click away from a mistimed Escape.
@(private = "file")
_pause_confirm :: proc(value: ^Client_State, surface: ^fit.Surface, x, y, width: i32) {
	height := ui_px(value.ui_scale, PAUSE_ROW_HEIGHT)
	advance := _pause_row_advance(value)
	row := y
	if fit.Surface_Button(
		surface,
		fit.Widget_Id_From_String("pause.exit.confirm"),
		"CONFIRM EXIT",
		fit.Rect{x, row, width, height},
		.Danger,
	) {
		value.quit_requested = true
	}
	row += advance
	if fit.Surface_Button(
		surface,
		fit.Widget_Id_From_String("pause.exit.cancel"),
		"CANCEL",
		fit.Rect{x, row, width, height},
		.Primary,
	) {
		value.pause.page = .Root
	}
}

package main

import "core:fmt"
import "core:time"
import fit "ingot:fit"
import rl "ingot:gfx"

Screen :: enum u8 {
	Menu,
	Playing,
	Loading,
	Loading_Graphics,
}

MENU_BUTTON_WIDTH :: i32(220)
MENU_BUTTON_HEIGHT :: i32(44)
MENU_CONTENT_HEIGHT :: i32(144)
// Offsets of the tagline and the start button below the title baseline.
MENU_TAGLINE_OFFSET :: i32(40)
MENU_BUTTON_OFFSET :: i32(100)
// Gap between the status line and the loading gauge.
MENU_BAR_OFFSET :: i32(40)
MENU_TITLE :: "TERRAFORGER"
MENU_TAGLINE :: "SCULPT · SETTLE · POWER A LIVING ISLAND"
// Cells in the bracketed loading gauge. A segmented readout carries the
// same information as a smooth bar but reads as instrumentation, and its
// quantisation makes slow progress visible as a step rather than as a
// creep the eye cannot resolve.
MENU_GAUGE_CELLS :: 24

// menu_backdrop fills the screen with the app ground and lays the same
// scanline wash every panel carries, so the menu and the in-game HUD are
// obviously the same instrument.
@(private = "file")
menu_backdrop :: proc(
	value: ^Client_State,
	surface: ^fit.Surface,
	screen_width, screen_height: i32,
) {
	assert(value != nil, "menu_backdrop: nil state")
	assert(surface != nil, "menu_backdrop: nil surface")
	tokens := fit.Get_Theme_Tokens(surface)
	fit.Fill_Rect(surface, fit.Rect{0, 0, screen_width, screen_height}, tokens.background_color)
	ui_scanlines(
		value,
		surface,
		fit.Float_Rect{0, 0, f32(screen_width), f32(screen_height)},
	)
}

// menu_gauge renders a bracketed segment bar: [####------]. Returns the
// string so the caller can measure it; the buffer is caller-owned because
// this runs every frame and must not allocate.
@(private = "file")
menu_gauge :: proc(buffer: []u8, progress: f32) -> string {
	assert(len(buffer) >= MENU_GAUGE_CELLS + 2, "menu_gauge: buffer too small")
	clamped := clamp(progress, 0, 1)
	filled := int(clamped * f32(MENU_GAUGE_CELLS) + 0.5)
	assert(filled >= 0 && filled <= MENU_GAUGE_CELLS, "menu_gauge: cell count out of range")
	buffer[0] = '['
	for index in 0 ..< MENU_GAUGE_CELLS {
		buffer[index + 1] = '#' if index < filled else '-'
	}
	buffer[MENU_GAUGE_CELLS + 1] = ']'
	return string(buffer[:MENU_GAUGE_CELLS + 2])
}

menu_frame :: proc(value: ^Client_State, surface: ^fit.Surface, screen_width, screen_height: i32) {
	assert(value != nil, "menu_frame: nil state")
	assert(surface != nil, "menu_frame: nil surface")
	assert(value.screen == .Menu, "menu_frame: wrong screen")
	menu_backdrop(value, surface, screen_width, screen_height)
	center_x := screen_width / 2
	title_y := (screen_height - ui_px(value.ui_scale, MENU_CONTENT_HEIGHT)) / 2
	title_width := fit.Text_Width(surface, MENU_TITLE, .Title)
	fit.Text(surface, MENU_TITLE, center_x - title_width / 2, title_y, .Title, .Heading)
	note_width := fit.Text_Width(surface, MENU_TAGLINE, .Note)
	fit.Text(
		surface,
		MENU_TAGLINE,
		center_x - note_width / 2,
		title_y + ui_px(value.ui_scale, MENU_TAGLINE_OFFSET),
		.Note,
		.Label,
	)
	button_width := ui_px(value.ui_scale, MENU_BUTTON_WIDTH)
	start_rect := fit.Rect {
		center_x - button_width / 2,
		title_y + ui_px(value.ui_scale, MENU_BUTTON_OFFSET),
		button_width,
		ui_px(value.ui_scale, MENU_BUTTON_HEIGHT),
	}
	if fit.Surface_Button(
		surface,
		fit.Widget_Id_From_String("menu.start"),
		"INITIALISE WORLD",
		start_rect,
		.Primary,
	) {
		value.screen = .Loading
	}
}

loading_frame :: proc(
	value: ^Client_State,
	surface: ^fit.Surface,
	screen_width, screen_height: i32,
) {
	assert(value != nil, "loading_frame: nil state")
	assert(surface != nil, "loading_frame: nil surface")
	assert(value.screen == .Loading || value.screen == .Loading_Graphics, "loading_frame: wrong screen")
	menu_backdrop(value, surface, screen_width, screen_height)
	// A boot log rather than a spinner: each line names the stage that is
	// actually running, so a long load looks like work instead of a hang.
	messages := [4]string {
		"> GENERATING SUBSTRATE",
		"> GENERATING SUBSTRATE .",
		"> GENERATING SUBSTRATE . .",
		"> GENERATING SUBSTRATE . . .",
	}
	message := messages[int(rl.GetTime() * 4) %% len(messages)]
	center_x := screen_width / 2
	center_y := screen_height / 2
	title_advance := fit.Text_Line_Height(surface, .Title)
	title_width := fit.Text_Width(surface, MENU_TITLE, .Title)
	fit.Text(
		surface,
		MENU_TITLE,
		center_x - title_width / 2,
		center_y - 2 * title_advance,
		.Title,
		.Heading,
	)
	note_width := fit.Text_Width(surface, message, .Note)
	fit.Text(surface, message, center_x - note_width / 2, center_y, .Note, .Accent)
	// Terrain builds incrementally across loading frames; the gauge shows
	// the world is being generated rather than frozen. It spans chunk
	// generation and the material bake, matching the gate that releases the
	// Playing transition.
	if value.terrain.build_active || terrain_material_bake_pending(&value.terrain) {
		progress := terrain_build_progress(&value.terrain)
		buffer: [MENU_GAUGE_CELLS + 2]u8
		gauge := menu_gauge(buffer[:], progress)
		gauge_width := fit.Text_Width(surface, gauge, .Note)
		fit.Text(
			surface,
			gauge,
			center_x - gauge_width / 2,
			center_y + ui_px(value.ui_scale, MENU_BAR_OFFSET),
			.Note,
			.Success,
		)
		percent := fmt.tprintf("%3d%%", int(clamp(progress, 0, 1) * 100))
		percent_width := fit.Text_Width(surface, percent, .Note)
		fit.Text(
			surface,
			percent,
			center_x - percent_width / 2,
			center_y +
			ui_px(value.ui_scale, MENU_BAR_OFFSET) +
			fit.Text_Line_Height(surface, .Note),
			.Note,
			.Label,
		)
	}
	if value.screen == .Loading {
		value.screen = .Loading_Graphics
	} else {
		probe := time.tick_now()
		loading_update(value)
		elapsed := time.tick_since(probe)
		// Above LOADING_BUILD_BUDGET plus slack: the chunk-upload phase is
		// deliberately budgeted at 40 ms, so a lower bar logs every frame.
		if elapsed > 50 * time.Millisecond {
			fmt.eprintln("[probe] loading_update frame took", elapsed)
		}
	}
}

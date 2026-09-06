package main

// console - Quake-style drop-down command console over the top half of the
// screen. Libvterm provides display state only; input is parsed and dispatched
// locally and no shell or PTY is spawned.

import shared "../shared"
import "core:c"
import "core:fmt"
import "core:math/rand"
import "core:strings"
import "core:unicode/utf8"
import fit "ingot:fit"
import rl "ingot:gfx"
import lv "ingot:libvterm"
import "ingot:prefs"
import term "ingot:term"

CONSOLE_FONT_SIZE :: i32(18)
// Leading added to the font size to form the cell height.
CONSOLE_LINE_GAP :: i32(4)
// Command hint strip along the panel's bottom edge.
CONSOLE_HINT_FONT_SIZE :: i32(14)
CONSOLE_HINT_MARGIN :: i32(6)
CONSOLE_PAD :: i32(8)
CONSOLE_MAX_LINE :: 256
CONSOLE_MAX_COLS :: 500
CONSOLE_MIN_COLS :: i32(20)
CONSOLE_MIN_ROWS :: i32(5)
// Worst case: CONSOLE_MAX_COLS cells x 4 UTF-8 bytes + NUL terminator.
CONSOLE_RUN_CAP :: CONSOLE_MAX_COLS * 4 + 1
// Aliases onto the palette; the vterm code compares cell colours against
// these, so they must be values rather than theme lookups.
CONSOLE_PANEL_COLOR :: UI_CONSOLE_GROUND
CONSOLE_DEFAULT_FG :: UI_CONSOLE_TEXT
// Thickness of the phosphor rule closing the panel's bottom edge.
CONSOLE_RULE_HEIGHT :: i32(2)
PREFS_FILE :: "settings"
CONSOLE_PROMPT :: "> "
CONSOLE_HISTORY_CAP :: 32

Console_Command :: enum u8 {
	Invalid,
	Set_Hud_On,
	Set_Hud_Off,
	Set_Fps_On,
	Set_Fps_Off,
	Clear_Resources,
	Clear_Resource_Nodes,
	Clear_Trees,
	Flora_Stats,
	Flora_Regenerate,
	Ocean_Status,
	Map_Regenerate,
	Profile_On,
	Profile_Off,
	Debug_On,
	Debug_Off,
}

Console_Parsed_Command :: struct {
	kind: Console_Command,
	seed: u64,
}

Console :: struct {
	terminal:      ^term.Term_Instance,
	open:          bool,
	line:          [CONSOLE_MAX_LINE]u8,
	line_len:      int,
	line_cursor:   int,
	line_valid:    bool,
	history:       [CONSOLE_HISTORY_CAP][CONSOLE_MAX_LINE]u8,
	history_lens:  [CONSOLE_HISTORY_CAP]int,
	history_count: int,
	history_head:  int,
	history_index: int,
	draft:         [CONSOLE_MAX_LINE]u8,
	draft_len:     int,
}

Console_Edit_Input :: struct {
	backspace: bool,
	delete:    bool,
	left:      bool,
	right:     bool,
	home:      bool,
	end:       bool,
	up:        bool,
	down:      bool,
}

// console_cell_metrics derives the monospace cell grid from the default
// font (JetBrains Mono). MeasureText returns 0 until the GPU context is up.
// The scale is the frame's UI scale: the panel's font has to grow with the
// monitor DPI on Windows, and the cell grid with it, or the reflow maths
// disagrees with what is drawn.
console_cell_metrics :: proc(scale: f32) -> (cell_w, cell_h: f32, ok: bool) {
	font := rl.GetFontDefault()
	if font.glyphCount == 0 do return 0, 0, false
	font_size := ui_px(scale, CONSOLE_FONT_SIZE)
	cell_w = rl.MeasureTextEx(font, "M", f32(font_size), 0).x
	cell_h = f32(font_size + ui_px(scale, CONSOLE_LINE_GAP))
	return cell_w, cell_h, cell_w > 0
}

console_grid_size :: proc(scale: f32) -> (cols, rows: u16, ok: bool) {
	cell_w, cell_h, metrics_ok := console_cell_metrics(scale)
	if !metrics_ok do return 0, 0, false
	width := rl.GetScreenWidth()
	height := rl.GetScreenHeight() / 2
	pad := ui_px(scale, CONSOLE_PAD)
	cols = u16(clamp(i32(f32(width - 2 * pad) / cell_w), CONSOLE_MIN_COLS, CONSOLE_MAX_COLS))
	rows = u16(
		clamp(
			i32(f32(height - 2 * pad - ui_px(scale, CONSOLE_FONT_SIZE)) / cell_h),
			CONSOLE_MIN_ROWS,
			200,
		),
	)
	return cols, rows, true
}

// console_toggle_pressed: GRAVE covers ANSI layouts; the '§'/'±' characters
// cover ISO Mac keyboards where the key above Tab reports no GRAVE keycode.
console_toggle_pressed :: proc(surface: ^fit.Surface) -> bool {
	if fit.Key_Pressed(surface, .Grave) do return true
	for codepoint in fit.Surface_Characters(surface) {
		if codepoint == '§' || codepoint == '±' do return true
	}
	return false
}

console_update :: proc(value: ^Client_State, surface: ^fit.Surface) {
	assert(surface != nil, "console_update: nil surface")
	console := &value.console
	toggled := console_toggle_pressed(surface)
	if toggled {
		console.open = !console.open
		if console.open && console.terminal == nil do console_start(console, value.ui_scale)
	}
	if !console.open || console.terminal == nil do return
	if toggled do return
	console_handle_input(value, surface)
}

console_start :: proc(console: ^Console, scale: f32) {
	assert(console != nil, "console_start: nil console")
	assert(console.terminal == nil, "console_start: terminal already running")
	cols, rows, ok := console_grid_size(scale)
	if !ok do return
	ts := new(term.Term_Instance)
	if ts == nil do return
	if !term.term_init_emulator(
		ts,
		cols,
		rows,
		{CONSOLE_DEFAULT_FG.r, CONSOLE_DEFAULT_FG.g, CONSOLE_DEFAULT_FG.b},
		{CONSOLE_PANEL_COLOR.r, CONSOLE_PANEL_COLOR.g, CONSOLE_PANEL_COLOR.b},
	) {
		free(ts)
		return
	}
	console.terminal = ts
	console_reset_line(console)
	console_write(ts, CONSOLE_PROMPT)
}

console_reset_line :: proc(console: ^Console) {
	assert(console != nil, "console_reset_line: nil console")
	console.line_len = 0
	console.line_cursor = 0
	console.line_valid = true
	console.history_index = 0
	console.draft_len = 0
}

// console_history_push records a submitted line in the ring buffer. Empty
// lines and exact repeats of the newest entry are dropped so Up walks a
// deduplicated list.
console_history_push :: proc(console: ^Console, line: string) {
	assert(console != nil, "console_history_push: nil console")
	if len(line) == 0 || len(line) > CONSOLE_MAX_LINE do return
	if console_history_entry(console, 1) == line do return
	copy(console.history[console.history_head][:], transmute([]u8)line)
	console.history_lens[console.history_head] = len(line)
	console.history_head = (console.history_head + 1) % CONSOLE_HISTORY_CAP
	if console.history_count < CONSOLE_HISTORY_CAP do console.history_count += 1
}

// console_history_entry maps a 1-based recency index (1 = newest) onto the ring.
console_history_entry :: proc(console: ^Console, index: int) -> string {
	assert(console != nil, "console_history_entry: nil console")
	if index < 1 || index > console.history_count do return ""
	slot := (console.history_head - index + CONSOLE_HISTORY_CAP * 2) % CONSOLE_HISTORY_CAP
	return string(console.history[slot][:console.history_lens[slot]])
}

// console_history_recall replaces the edit line with history entry index, or
// with the stashed draft when index is 0.
console_history_recall :: proc(console: ^Console, index: int) {
	assert(console != nil, "console_history_recall: nil console")
	text :=
		index == 0 \
		? string(console.draft[:console.draft_len]) \
		: console_history_entry(console, index)
	copy(console.line[:], transmute([]u8)text)
	console.line_len = len(text)
	console.line_cursor = console.line_len
	console.line_valid = true
}

console_insert_text :: proc(console: ^Console, text: string) {
	assert(console != nil, "console_insert_text: nil console")
	if len(text) == 0 do return
	if len(text) > CONSOLE_MAX_LINE - console.line_len {
		console.line_valid = false
		return
	}
	for byte in transmute([]u8)text {
		if byte < 0x20 || byte > 0x7e {
			console.line_valid = false
			return
		}
	}
	for index := console.line_len; index > console.line_cursor; index -= 1 {
		console.line[index + len(text) - 1] = console.line[index - 1]
	}
	copy(console.line[console.line_cursor:], transmute([]u8)text)
	console.line_len += len(text)
	console.line_cursor += len(text)
}

console_insert_rune :: proc(console: ^Console, codepoint: rune) {
	assert(console != nil, "console_insert_rune: nil console")
	if codepoint < 0x20 || codepoint > 0x7e {
		console.line_valid = false
		return
	}
	bytes := [1]u8{u8(codepoint)}
	console_insert_text(console, transmute(string)bytes[:])
}

console_edit_input :: proc(surface: ^fit.Surface) -> Console_Edit_Input {
	assert(surface != nil, "console_edit_input: nil surface")
	return {
		backspace = fit.Surface_Key_Pressed_Or_Repeat(surface, .Backspace),
		delete = fit.Surface_Key_Pressed_Or_Repeat(surface, .Delete),
		left = fit.Surface_Key_Pressed_Or_Repeat(surface, .Left),
		right = fit.Surface_Key_Pressed_Or_Repeat(surface, .Right),
		home = fit.Key_Pressed(surface, .Home),
		end = fit.Key_Pressed(surface, .End),
		up = fit.Surface_Key_Pressed_Or_Repeat(surface, .Up),
		down = fit.Surface_Key_Pressed_Or_Repeat(surface, .Down),
	}
}

console_handle_edit_keys :: proc(console: ^Console, input: Console_Edit_Input) {
	assert(console != nil, "console_handle_edit_keys: nil console")
	if input.up && console.history_count > 0 {
		if console.history_index == 0 {
			copy(console.draft[:], console.line[:console.line_len])
			console.draft_len = console.line_len
		}
		console.history_index = min(console.history_index + 1, console.history_count)
		console_history_recall(console, console.history_index)
		return
	}
	if input.down && console.history_index > 0 {
		console.history_index -= 1
		console_history_recall(console, console.history_index)
		return
	}
	if input.backspace && console.line_cursor > 0 {
		for index in console.line_cursor ..< console.line_len {
			console.line[index - 1] = console.line[index]
		}
		console.line_cursor -= 1
		console.line_len -= 1
	}
	if input.delete && console.line_cursor < console.line_len {
		for index in console.line_cursor + 1 ..< console.line_len {
			console.line[index - 1] = console.line[index]
		}
		console.line_len -= 1
	}
	if input.left && console.line_cursor > 0 do console.line_cursor -= 1
	if input.right && console.line_cursor < console.line_len do console.line_cursor += 1
	if input.home do console.line_cursor = 0
	if input.end do console.line_cursor = console.line_len
}

console_redraw_line :: proc(console: ^Console) {
	assert(console != nil, "console_redraw_line: nil console")
	if console.terminal == nil do return
	console_write(console.terminal, "\r\x1b[2K")
	console_write(console.terminal, CONSOLE_PROMPT)
	console_write(console.terminal, string(console.line[:console.line_len]))
	columns_back := console.line_len - console.line_cursor
	if columns_back > 0 {
		console_write(console.terminal, fmt.tprintf("\x1b[%dD", columns_back))
	}
}

console_handle_input :: proc(value: ^Client_State, surface: ^fit.Surface) {
	assert(value != nil, "console_handle_input: nil state")
	assert(surface != nil, "console_handle_input: nil surface")
	console := &value.console
	ctrl :=
		fit.Surface_Key_Down(surface, .Left_Control) ||
		fit.Surface_Key_Down(surface, .Right_Control)
	super :=
		fit.Surface_Key_Down(surface, .Left_Super) || fit.Surface_Key_Down(surface, .Right_Super)
	shift :=
		fit.Surface_Key_Down(surface, .Left_Shift) || fit.Surface_Key_Down(surface, .Right_Shift)
	if fit.Key_Pressed(surface, .V) && (super || (ctrl && shift)) {
		console_insert_text(console, fit.Surface_Clipboard(surface))
	} else if !ctrl && !super {
		for codepoint in fit.Surface_Characters(surface) {
			console_insert_rune(console, codepoint)
		}
	}
	console_handle_edit_keys(console, console_edit_input(surface))
	if fit.Key_Pressed(surface, .Enter) {
		console_submit(value)
	} else {
		console_redraw_line(console)
	}
}

console_command_parse :: proc(line: string) -> Console_Parsed_Command {
	switch line {
	case "set hud on":
		return {kind = .Set_Hud_On}
	case "set hud off":
		return {kind = .Set_Hud_Off}
	case "set fps on":
		return {kind = .Set_Fps_On}
	case "set fps off":
		return {kind = .Set_Fps_Off}
	case "clear resources":
		return {kind = .Clear_Resources}
	case "clear resource nodes":
		return {kind = .Clear_Resource_Nodes}
	case "clear trees":
		return {kind = .Clear_Trees}
	case "flora stats":
		return {kind = .Flora_Stats}
	case "flora regenerate":
		return {kind = .Flora_Regenerate}
	case "ocean status":
		return {kind = .Ocean_Status}
	case "profile on":
		return {kind = .Profile_On}
	case "profile off":
		return {kind = .Profile_Off}
	case "debug", "debug on":
		return {kind = .Debug_On}
	case "debug off":
		return {kind = .Debug_Off}
	case "map regenerate random":
		return {kind = .Map_Regenerate, seed = rand.uint64()}
	}
	prefix := "map regenerate "
	if !strings.has_prefix(line, prefix) do return {}
	text := line[len(prefix):]
	if len(text) == 0 do return {}
	seed: u64
	for byte in transmute([]u8)text {
		if byte < '0' || byte > '9' do return {}
		digit := u64(byte - '0')
		if seed > (max(u64) - digit) / 10 do return {}
		seed = seed * 10 + digit
	}
	return {kind = .Map_Regenerate, seed = seed}
}

console_command_closes_console :: proc(command: Console_Command) -> bool {
	return command == .Debug_On || command == .Debug_Off
}

console_command_execute :: proc(value: ^Client_State, command: Console_Parsed_Command) {
	assert(value != nil, "console_command_execute: nil state")
	switch command.kind {
	case .Set_Hud_On:
		value.show_hud_text = true
		console_print(value.console.terminal, "[terraforger] hud text on")
		settings_save(value)
	case .Set_Hud_Off:
		value.show_hud_text = false
		console_print(value.console.terminal, "[terraforger] hud text off")
		settings_save(value)
	case .Set_Fps_On:
		value.show_fps = true
		console_print(value.console.terminal, "[terraforger] fps counter on")
		settings_save(value)
	case .Set_Fps_Off:
		value.show_fps = false
		console_print(value.console.terminal, "[terraforger] fps counter off")
		settings_save(value)
	case .Clear_Resources:
		node_count := console_clear_resource_nodes(value)
		tree_count := flora_clear_trees(&value.flora)
		message := fmt.tprintf(
			"[terraforger] cleared %d resource nodes and %d trees",
			node_count,
			tree_count,
		)
		console_print(value.console.terminal, message)
	case .Clear_Resource_Nodes:
		count := console_clear_resource_nodes(value)
		message := fmt.tprintf("[terraforger] cleared %d resource nodes", count)
		console_print(value.console.terminal, message)
	case .Clear_Trees:
		count := flora_clear_trees(&value.flora)
		message := fmt.tprintf("[terraforger] cleared %d trees", count)
		console_print(value.console.terminal, message)
	case .Flora_Stats:
		counts := flora_counts(&value.flora)
		message := fmt.tprintf(
			"[terraforger] flora conifers=%d broadleaf=%d grass=%d boulders=%d scree=%d hidden=%d visits=%d submitted=%d",
			counts.conifers,
			counts.broadleaf,
			counts.grass,
			counts.boulders,
			counts.scree,
			counts.hidden,
			value.flora.draw_visits,
			value.flora.draw_submitted,
		)
		console_print(value.console.terminal, message)
	case .Flora_Regenerate:
		flora_regenerate(&value.flora, &value.terrain, &value.world, &value.ruins)
		console_print(value.console.terminal, "[terraforger] flora regenerated")
	case .Ocean_Status:
		console_ocean_status(value)
	case .Profile_On:
		value.profiler.visible = true
		console_print(value.console.terminal, "[terraforger] profile overlay on")
		settings_save(value)
	case .Profile_Off:
		value.profiler.visible = false
		console_print(value.console.terminal, "[terraforger] profile overlay off")
		settings_save(value)
	case .Debug_On:
		value.debug.open = true
		console_print(value.console.terminal, "[terraforger] debug panel on (F10 toggles)")
		settings_save(value)
	case .Debug_Off:
		value.debug.open = false
		console_print(value.console.terminal, "[terraforger] debug panel off")
		settings_save(value)
	case .Map_Regenerate:
		value.regenerate_seed = command.seed
		value.regenerate_pending = true
		console_print(
			value.console.terminal,
			fmt.tprintf("[terraforger] regenerating map seed=%d", command.seed),
		)
	case .Invalid:
		unreachable()
	}
}

console_submit :: proc(value: ^Client_State) {
	assert(value != nil, "console_submit: nil state")
	console := &value.console
	console_write(console.terminal, "\r\n")
	line := strings.trim_space(string(console.line[:console.line_len]))
	if console.line_valid do console_history_push(console, line)
	command := console_command_parse(line) if console.line_valid else Console_Parsed_Command{}
	if command.kind == .Invalid {
		console_print(console.terminal, "[terraforger] command not allowed")
	} else {
		console_command_execute(value, command)
		if console_command_closes_console(command.kind) do console.open = false
	}
	console_reset_line(console)
	console_write(console.terminal, CONSOLE_PROMPT)
}

console_clear_resource_nodes :: proc(value: ^Client_State) -> u32 {
	assert(value != nil, "console_clear_resource_nodes: nil state")
	count := shared.world_clear_resource_nodes(&value.world)
	value.hover_entity = {}
	value.hover_entity_seconds = 0
	entity_queries_sync(value)
	value.sockets.dirty = true
	return count
}

console_write :: proc(ts: ^term.Term_Instance, text: string) {
	if ts == nil || len(text) == 0 do return
	bytes := transmute([]u8)text
	lv.vterm_input_write(ts.vt, raw_data(bytes), c.size_t(len(bytes)))
}

console_print :: proc(ts: ^term.Term_Instance, message: string) {
	console_write(ts, fmt.tprintf("%s\r\n", message))
}

// console_cell_colors resolves a cell's vterm colors to rl.Color, honoring
// theme defaults and the reverse attribute. bg_default reports whether the
// background matches the panel color (so the caller can skip the bg rect).
console_cell_colors :: proc(
	ts: ^term.Term_Instance,
	cell: ^lv.VTerm_Screen_Cell,
) -> (
	fg: rl.Color,
	bg: rl.Color,
	bg_default: bool,
) {
	fg = CONSOLE_DEFAULT_FG
	if !lv.vterm_color_is_default_fg(&cell.fg) {
		lv.vterm_screen_convert_color_to_rgb(ts.screen, &cell.fg)
		fg = {cell.fg.rgb.red, cell.fg.rgb.green, cell.fg.rgb.blue, 255}
	}
	bg = CONSOLE_PANEL_COLOR
	bg_default = true
	if !lv.vterm_color_is_default_bg(&cell.bg) {
		lv.vterm_screen_convert_color_to_rgb(ts.screen, &cell.bg)
		bg = {cell.bg.rgb.red, cell.bg.rgb.green, cell.bg.rgb.blue, 255}
		bg_default = false
	}
	if cell.attrs.reverse != 0 {
		fg, bg = bg, fg
		bg_default = false
	}
	return fg, bg, bg_default
}

// console_draw_run flushes one same-color text run at a cell position.
console_draw_run :: proc(
	surface: ^fit.Surface,
	run: []u8,
	run_len: int,
	run_col, row: i32,
	cell_w, cell_h: f32,
	color: rl.Color,
	pad, font_size: i32,
) {
	if run_len == 0 do return
	assert(surface != nil, "console_draw_run: nil surface")
	assert(run_len < len(run), "console_draw_run: run buffer full")
	fit.Text_Wrapped(
		surface,
		string(run[:run_len]),
		pad + i32(f32(run_col) * cell_w),
		pad + i32(f32(row) * cell_h),
		rl.GetScreenWidth(),
		fit.Color(color),
		font_size,
		i32(cell_h),
	)
}

// console_draw renders the drop-down panel over the top half of the screen.
// Called from draw_screen after tooltip_draw, before cursor_draw.
console_draw :: proc(value: ^Client_State, surface: ^fit.Surface) {
	assert(surface != nil, "console_draw: nil surface")
	console := &value.console
	if !console.open || console.terminal == nil do return
	ts := console.terminal
	cell_w, cell_h, metrics_ok := console_cell_metrics(value.ui_scale)
	if !metrics_ok do return
	pad := ui_px(value.ui_scale, CONSOLE_PAD)
	font_size := ui_px(value.ui_scale, CONSOLE_FONT_SIZE)
	width := rl.GetScreenWidth()
	panel_h := rl.GetScreenHeight() / 2
	claim := fit.Float_Rect{0, 0, f32(width), f32(panel_h)}
	fit.Layer_Begin(surface, fit.Z_POPUP, claim)
	defer fit.Layer_End(surface)
	panel := fit.Float_Rect{0, 0, f32(width), f32(panel_h)}
	fit.Fill_Rect(surface, fit.Rect{0, 0, width, panel_h}, fit.Color(CONSOLE_PANEL_COLOR))
	// Scanlines before the text, so the glyphs sit on the wash rather than
	// under it; a scanline over a glyph reads as a rendering fault.
	ui_scanlines(value, surface, panel)
	rule := ui_px(value.ui_scale, CONSOLE_RULE_HEIGHT)
	fit.Fill_Rect(
		surface,
		fit.Rect{0, panel_h - rule, width, rule},
		fit.Color(UI_GLOW),
	)
	// Re-flow the emulator grid when the window size changed.
	cols, rows, grid_ok := console_grid_size(value.ui_scale)
	if grid_ok && (cols != ts.cols || rows != ts.rows) {
		ts.cols = cols
		ts.rows = rows
		lv.vterm_set_size(ts.vt, c.int(rows), c.int(cols))
		console_redraw_line(console)
	}
	// Batch runs of same-fg text per row; monospace keeps columns exact.
	run: [CONSOLE_RUN_CAP]u8
	for row in 0 ..< i32(ts.rows) {
		run_len := 0
		run_col := i32(0)
		run_color := CONSOLE_DEFAULT_FG
		for col in 0 ..< i32(ts.cols) {
			cell: lv.VTerm_Screen_Cell
			lv.vterm_screen_get_cell(
				ts.screen,
				lv.VTerm_Pos{row = c.int(row), col = c.int(col)},
				&cell,
			)
			if cell.width <= 0 do continue // double-width continuation
			fg, bg, bg_default := console_cell_colors(ts, &cell)
			if !bg_default {
				fit.Fill_Rect(
					surface,
					fit.Float_Rect {
						f32(CONSOLE_PAD) + f32(col) * cell_w,
						f32(CONSOLE_PAD) + f32(row) * cell_h,
						cell_w * f32(cell.width),
						cell_h,
					},
					fit.Color(bg),
				)
			}
			codepoint := rune(cell.chars[0])
			if codepoint == 0 do codepoint = ' '
			if fg != run_color || run_len + utf8.UTF_MAX >= CONSOLE_RUN_CAP {
				console_draw_run(
					surface,
					run[:],
					run_len,
					run_col,
					row,
					cell_w,
					cell_h,
					run_color,
					pad,
					font_size,
				)
				run_len = 0
				run_col = col
				run_color = fg
			}
			encoded, encoded_len := utf8.encode_rune(codepoint)
			copy(run[run_len:], encoded[:encoded_len])
			run_len += encoded_len
			// Double-width glyphs occupy two columns; pad the run so the
			// following cells stay column-aligned under monospace metrics.
			if cell.width == 2 && run_len < CONSOLE_RUN_CAP - 1 {
				run[run_len] = ' '
				run_len += 1
			}
		}
		console_draw_run(
			surface,
			run[:],
			run_len,
			run_col,
			row,
			cell_w,
			cell_h,
			run_color,
			pad,
			font_size,
		)
	}
	cursor_phase_visible := !ts.cursor_blink || i64(rl.GetTime() * 2) % 2 == 0
	if ts.cursor_visible && cursor_phase_visible && ts.sb_view_offset == 0 {
		pos: lv.VTerm_Pos
		lv.vterm_state_get_cursorpos(ts.state, &pos)
		if pos.row >= 0 && pos.row < c.int(ts.rows) && pos.col >= 0 && pos.col < c.int(ts.cols) {
			x := f32(pad) + f32(pos.col) * cell_w
			y := f32(pad) + f32(pos.row) * cell_h
			cursor_w := cell_w
			cursor_h := cell_h
			switch ts.cursor_shape {
			case .Underline:
				cursor_h = 2
				y += cell_h - cursor_h
			case .Bar_Left:
				cursor_w = 2
			case .Block:
			}
			fit.Fill_Rect(
				surface,
				fit.Float_Rect{x, y, cursor_w, cursor_h},
				fit.Color(UI_CARET),
			)
		}
	}
	fit.Text_Wrapped(
		surface,
		"map regenerate <seed>|random   ocean status   set hud|fps on|off   profile on|off   debug|on|off   clear resources|resource nodes|trees   flora stats|regenerate   § close",
		pad,
		panel_h - font_size - ui_px(value.ui_scale, CONSOLE_HINT_MARGIN),
		width - pad * 2,
		fit.Get_Theme_Tokens(surface).foreground_label,
		ui_px(value.ui_scale, CONSOLE_HINT_FONT_SIZE),
		font_size,
	)
}

console_shutdown :: proc(console: ^Console) {
	assert(console != nil, "console_shutdown: nil console")
	if console.terminal != nil {
		term.term_free_emulator(console.terminal)
		free(console.terminal)
		console.terminal = nil
	}
	console.open = false
}

// settings_load restores the HUD toggles from the prefs file; missing or
// malformed files leave the defaults (everything visible).
settings_load :: proc(value: ^Client_State) {
	assert(value != nil, "settings_load: nil state")
	value.show_hud_text = true
	value.show_fps = true
	value.debug.detail_mode = .Simple
	settings_demo_defaults(value)
	data, ok := prefs.read(game_prefs_app(), PREFS_FILE)
	if !ok do return
	text := string(data)
	for line in strings.split_lines_iterator(&text) {
		key, _, val := strings.partition(line, "=")
		switch key {
		case "hud":
			value.show_hud_text = val != "0"
		case "fps":
			value.show_fps = val != "0"
		case "profile":
			value.profiler.visible = val != "0"
		case "debug":
			value.debug.open = val != "0"
		case "debug_advanced":
			value.debug.detail_mode = .Advanced if val == "1" else .Simple
		case "flora_density":
			debug_tuning.flora_density_scale = clamp(
				debug_parse_f32(val, 1),
				0,
				DEBUG_FLORA_DENSITY_MAX,
			)
		case:
			_ = settings_demo_load(value, key, val)
		}
	}
}

settings_save :: proc(value: ^Client_State) {
	assert(value != nil, "settings_save: nil state")
	demo := settings_demo_text(value)
	text := fmt.tprintf(
		"hud=%d\nfps=%d\nprofile=%d\ndebug=%d\ndebug_advanced=%d\nflora_density=%.3f\n%s",
		int(value.show_hud_text),
		int(value.show_fps),
		int(value.profiler.visible),
		int(value.debug.open),
		int(value.debug.detail_mode == .Advanced),
		debug_tuning.flora_density_scale,
		demo,
	)
	prefs.write(game_prefs_app(), PREFS_FILE, transmute([]u8)text)
}

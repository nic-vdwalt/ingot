#+build !js
package main

import "core:fmt"
import "core:testing"

@(test)
console_parser_accepts_only_whitelisted_commands :: proc(t: ^testing.T) {
	accepted := []struct {
		text: string,
		want: Console_Command,
	} {
		{"set hud on", .Set_Hud_On},
		{"set hud off", .Set_Hud_Off},
		{"set fps on", .Set_Fps_On},
		{"set fps off", .Set_Fps_Off},
		{"clear resources", .Clear_Resources},
		{"clear resource nodes", .Clear_Resource_Nodes},
		{"clear trees", .Clear_Trees},
		{"flora stats", .Flora_Stats},
		{"flora regenerate", .Flora_Regenerate},
		{"ocean status", .Ocean_Status},
		{"profile on", .Profile_On},
		{"profile off", .Profile_Off},
	}
	for test in accepted {
		testing.expect_value(t, console_command_parse(test.text).kind, test.want)
	}

	rejected := []string {
		"",
		"pwd",
		"ls",
		"sh",
		"/bin/sh",
		"touch test",
		"clear trees; pwd",
		"clear trees | cat",
		"clear trees > file",
		"$(pwd)",
		"CLEAR TREES",
		"clear trees now",
		"flora stats; pwd",
		"flora stats | cat",
		"flora regenerate > file",
		"FLORA STATS",
		"flora stats now",
		"OCEAN STATUS",
		"ocean  status",
		"ocean status now",
		"ocean status; pwd",
		"set hud",
		"set fps maybe",
		"set  hud on",
		" set hud on",
		"set hud on ",
	}
	for text in rejected {
		testing.expect_value(t, console_command_parse(text).kind, Console_Command.Invalid)
	}
}

@(test)
debug_console_commands_close_the_console :: proc(t: ^testing.T) {
	testing.expect(t, console_command_closes_console(.Debug_On))
	testing.expect(t, console_command_closes_console(.Debug_Off))
	testing.expect(t, !console_command_closes_console(.Profile_On))
	testing.expect(t, !console_command_closes_console(.Ocean_Status))
	testing.expect(t, !console_command_closes_console(.Invalid))
}

@(test)
console_parser_accepts_bounded_map_seeds :: proc(t: ^testing.T) {
	zero := console_command_parse("map regenerate 0")
	testing.expect_value(t, zero.kind, Console_Command.Map_Regenerate)
	testing.expect_value(t, zero.seed, u64(0))
	maximum := console_command_parse("map regenerate 18446744073709551615")
	testing.expect_value(t, maximum.kind, Console_Command.Map_Regenerate)
	testing.expect_value(t, maximum.seed, max(u64))
	random := console_command_parse("map regenerate random")
	testing.expect_value(t, random.kind, Console_Command.Map_Regenerate)

	rejected := []string {
		"map regenerate",
		"map regenerate ",
		"map regenerate -1",
		"map regenerate +1",
		"map regenerate 0x10",
		"map regenerate 18446744073709551616",
		"map regenerate 1 2",
		"map regenerate  1",
		"map regenerate RANDOM",
		"map regenerate 1; pwd",
	}
	for text in rejected {
		testing.expect_value(t, console_command_parse(text).kind, Console_Command.Invalid)
	}
}

@(test)
console_editor_rejects_unsafe_or_overlong_input :: proc(t: ^testing.T) {
	console: Console
	console_reset_line(&console)
	console_insert_text(&console, "clear trees")
	testing.expect(t, console.line_valid)
	testing.expect_value(t, string(console.line[:console.line_len]), "clear trees")
	testing.expect_value(t, console.line_cursor, len("clear trees"))

	console.line_cursor = len("clear ")
	console_insert_text(&console, "resource ")
	testing.expect_value(t, string(console.line[:console.line_len]), "clear resource trees")
	testing.expect_value(t, console.line_cursor, len("clear resource "))

	before := string(console.line[:console.line_len])
	console_insert_text(&console, "\nls")
	testing.expect(t, !console.line_valid)
	testing.expect_value(t, string(console.line[:console.line_len]), before)

	console_reset_line(&console)
	console_insert_text(&console, "trées")
	testing.expect(t, !console.line_valid)
	testing.expect_value(t, console.line_len, 0)

	console_reset_line(&console)
	full: [CONSOLE_MAX_LINE]u8
	for &byte in full do byte = 'a'
	console_insert_text(&console, transmute(string)full[:])
	testing.expect(t, console.line_valid)
	testing.expect_value(t, console.line_len, CONSOLE_MAX_LINE)
	console_insert_text(&console, "b")
	testing.expect(t, !console.line_valid)
	testing.expect_value(t, console.line_len, CONSOLE_MAX_LINE)
}

@(test)
console_editor_navigation_stays_in_bounds :: proc(t: ^testing.T) {
	console: Console
	input: Console_Edit_Input
	console_reset_line(&console)
	console_insert_text(&console, "abc")

	input.left = true
	console_handle_edit_keys(&console, input)
	testing.expect_value(t, console.line_cursor, 2)
	input = {}

	input.backspace = true
	console_handle_edit_keys(&console, input)
	testing.expect_value(t, string(console.line[:console.line_len]), "ac")
	testing.expect_value(t, console.line_cursor, 1)
	input = {}

	input.delete = true
	console_handle_edit_keys(&console, input)
	testing.expect_value(t, string(console.line[:console.line_len]), "a")
	testing.expect_value(t, console.line_cursor, 1)
	input = {}

	input.home = true
	console_handle_edit_keys(&console, input)
	testing.expect_value(t, console.line_cursor, 0)
	input = {}

	input.backspace = true
	console_handle_edit_keys(&console, input)
	testing.expect_value(t, console.line_cursor, 0)
	testing.expect_value(t, console.line_len, 1)
	input = {}

	input.end = true
	console_handle_edit_keys(&console, input)
	testing.expect_value(t, console.line_cursor, 1)
}

@(test)
console_history_recalls_previous_commands :: proc(t: ^testing.T) {
	console: Console
	console_reset_line(&console)
	console_history_push(&console, "set hud on")
	console_history_push(&console, "flora stats")
	console_history_push(&console, "clear trees")

	up: Console_Edit_Input
	up.up = true
	console_handle_edit_keys(&console, up)
	testing.expect_value(t, string(console.line[:console.line_len]), "clear trees")
	testing.expect_value(t, console.line_cursor, len("clear trees"))
	console_handle_edit_keys(&console, up)
	testing.expect_value(t, string(console.line[:console.line_len]), "flora stats")
	console_handle_edit_keys(&console, up)
	testing.expect_value(t, string(console.line[:console.line_len]), "set hud on")
	console_handle_edit_keys(&console, up)
	testing.expect_value(t, string(console.line[:console.line_len]), "set hud on")
	testing.expect_value(t, console.history_index, 3)

	down: Console_Edit_Input
	down.down = true
	console_handle_edit_keys(&console, down)
	testing.expect_value(t, string(console.line[:console.line_len]), "flora stats")
}

@(test)
console_history_down_restores_draft :: proc(t: ^testing.T) {
	console: Console
	console_reset_line(&console)
	console_history_push(&console, "flora stats")
	console_insert_text(&console, "clear tr")

	up: Console_Edit_Input
	up.up = true
	console_handle_edit_keys(&console, up)
	testing.expect_value(t, string(console.line[:console.line_len]), "flora stats")

	down: Console_Edit_Input
	down.down = true
	console_handle_edit_keys(&console, down)
	testing.expect_value(t, string(console.line[:console.line_len]), "clear tr")
	testing.expect_value(t, console.line_cursor, len("clear tr"))
	testing.expect_value(t, console.history_index, 0)

	console_handle_edit_keys(&console, down)
	testing.expect_value(t, string(console.line[:console.line_len]), "clear tr")
}

@(test)
console_history_ignores_empty_and_duplicates :: proc(t: ^testing.T) {
	console: Console
	console_reset_line(&console)
	console_history_push(&console, "")
	testing.expect_value(t, console.history_count, 0)

	console_history_push(&console, "flora stats")
	console_history_push(&console, "flora stats")
	testing.expect_value(t, console.history_count, 1)

	console_history_push(&console, "clear trees")
	console_history_push(&console, "flora stats")
	testing.expect_value(t, console.history_count, 3)
	testing.expect_value(t, console_history_entry(&console, 1), "flora stats")
	testing.expect_value(t, console_history_entry(&console, 3), "flora stats")
	testing.expect_value(t, console_history_entry(&console, 4), "")
	testing.expect_value(t, console_history_entry(&console, 0), "")

	up: Console_Edit_Input
	up.up = true
	empty: Console
	console_reset_line(&empty)
	console_insert_text(&empty, "abc")
	console_handle_edit_keys(&empty, up)
	testing.expect_value(t, string(empty.line[:empty.line_len]), "abc")
	testing.expect_value(t, empty.history_index, 0)
}

@(test)
console_history_wraps_at_capacity :: proc(t: ^testing.T) {
	console: Console
	console_reset_line(&console)
	total := CONSOLE_HISTORY_CAP + 5
	for index in 0 ..< total {
		console_history_push(&console, fmt.tprintf("cmd %d", index))
	}
	testing.expect_value(t, console.history_count, CONSOLE_HISTORY_CAP)
	testing.expect_value(t, console_history_entry(&console, 1), fmt.tprintf("cmd %d", total - 1))
	testing.expect_value(
		t,
		console_history_entry(&console, CONSOLE_HISTORY_CAP),
		fmt.tprintf("cmd %d", total - CONSOLE_HISTORY_CAP),
	)
	testing.expect_value(t, console_history_entry(&console, CONSOLE_HISTORY_CAP + 1), "")
}

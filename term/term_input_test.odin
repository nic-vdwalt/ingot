package term

import "core:testing"
import rl "ingot:gfx"
import "ingot:pty"
import "ingot:ui"

INGOT_TERM_PTY_SIM :: #config(INGOT_PTY_SIM, false)

@(test)
term_ui_input_reads_captured_characters :: proc(t: ^testing.T) {
	ts := new(Term_Instance)
	defer free(ts)
	when INGOT_TERM_PTY_SIM {
		ts.pty_running = true
	} else {
		when ODIN_OS == .Windows do return
		p, ok := pty.spawn("/bin/cat", 80, 24)
		testing.expect(t, ok, "failed to spawn PTY")
		if !ok do return
		defer pty.destroy(&p)
		ts.pty = p
		ts.pty_running = true
	}
	ts.sb_view_offset = 4
	input: ui.Ui_Input
	input.characters[0] = 'x'
	input.character_count = 1

	testing.expect(t, term_handle_ui_input(ts, &input))
	testing.expect_value(t, ts.sb_view_offset, 0)
}

@(test)
vt_key_map :: proc(t: ^testing.T) {
	b: [8]u8

	// Ctrl+A -> 0x01.
	n, ok := vt_bytes_for_key(.A, true, false, false, nil, b[:])
	testing.expect(t, ok && n == 1 && b[0] == 0x01, "Ctrl+A -> 0x01")

	// Ctrl+[ -> ESC (0x1B).
	n, ok = vt_bytes_for_key(.LEFT_BRACKET, true, false, false, nil, b[:])
	testing.expect(t, ok && n == 1 && b[0] == 0x1B, "Ctrl+[ -> ESC")

	// Enter -> CR.
	n, ok = vt_bytes_for_key(.ENTER, false, false, false, nil, b[:])
	testing.expect(t, ok && n == 1 && b[0] == '\r', "Enter -> CR")

	// Backspace -> DEL (0x7f).
	n, ok = vt_bytes_for_key(.BACKSPACE, false, false, false, nil, b[:])
	testing.expect(t, ok && n == 1 && b[0] == 0x7f, "Backspace -> 0x7f")

	// Shift+Tab -> CSI Z.
	n, ok = vt_bytes_for_key(.TAB, false, true, false, nil, b[:])
	testing.expect(t, ok && string(b[:n]) == "\x1b[Z", "Shift+Tab -> CSI Z")

	// Plain Tab -> HT.
	n, ok = vt_bytes_for_key(.TAB, false, false, false, nil, b[:])
	testing.expect(t, ok && n == 1 && b[0] == '\t', "Tab -> HT")

	// Arrows / navigation.
	n, ok = vt_bytes_for_key(.UP, false, false, false, nil, b[:])
	testing.expect(t, ok && string(b[:n]) == "\x1b[A", "Up -> CSI A")
	n, ok = vt_bytes_for_key(.HOME, false, false, false, nil, b[:])
	testing.expect(t, ok && string(b[:n]) == "\x1b[H", "Home -> CSI H")
	n, ok = vt_bytes_for_key(.PAGE_UP, false, false, false, nil, b[:])
	testing.expect(t, ok && string(b[:n]) == "\x1b[5~", "PageUp -> CSI 5~")

	// Function keys.
	n, ok = vt_bytes_for_key(.F1, false, false, false, nil, b[:])
	testing.expect(t, ok && string(b[:n]) == "\x1bOP", "F1 -> SS3 P")
	n, ok = vt_bytes_for_key(.F5, false, false, false, nil, b[:])
	testing.expect(t, ok && string(b[:n]) == "\x1b[15~", "F5 -> CSI 15~")

	// Ctrl+Shift+T reserved by host app -> not forwarded.
	_, ok = vt_bytes_for_key(.T, true, true, false, {rl.KeyboardKey.T}, b[:])
	testing.expect(t, !ok, "skipped Ctrl+Shift chord emits nothing")

	// Ctrl+Shift+A that is NOT in the skip list still maps to 0x01.
	n, ok = vt_bytes_for_key(.A, true, true, false, {rl.KeyboardKey.T}, b[:])
	testing.expect(t, ok && n == 1 && b[0] == 0x01, "unlisted Ctrl+Shift+A still forwards")

	// Unmapped key -> ok=false.
	_, ok = vt_bytes_for_key(.SPACE, false, false, false, nil, b[:])
	testing.expect(t, !ok, "unmapped key emits nothing")

	// Super (Cmd) combos are not control codes here.
	_, ok = vt_bytes_for_key(.C, false, false, true, nil, b[:])
	testing.expect(t, !ok, "Cmd+C is not a control code")
}

@(test)
vt_key_map_control_contract :: proc(t: ^testing.T) {
	b: [8]u8
	ctrl_cases := []struct {
		key:      rl.KeyboardKey,
		expected: u8,
	} {
		{.A, 0x01},
		{.B, 0x02},
		{.C, 0x03},
		{.D, 0x04},
		{.E, 0x05},
		{.F, 0x06},
		{.G, 0x07},
		{.H, 0x08},
		{.I, 0x09},
		{.J, 0x0A},
		{.K, 0x0B},
		{.L, 0x0C},
		{.M, 0x0D},
		{.N, 0x0E},
		{.O, 0x0F},
		{.P, 0x10},
		{.Q, 0x11},
		{.R, 0x12},
		{.S, 0x13},
		{.T, 0x14},
		{.U, 0x15},
		{.V, 0x16},
		{.W, 0x17},
		{.X, 0x18},
		{.Y, 0x19},
		{.Z, 0x1A},
		{.LEFT_BRACKET, 0x1B},
		{.BACKSLASH, 0x1C},
		{.RIGHT_BRACKET, 0x1D},
		{.GRAVE, 0x1E},
	}
	for test_case in ctrl_cases {
		n, ok := vt_bytes_for_key(test_case.key, true, false, false, nil, b[:])
		testing.expect(t, ok)
		testing.expect_value(t, n, 1)
		testing.expect_value(t, b[0], test_case.expected)
	}
}

@(test)
vt_key_map_sequence_contract :: proc(t: ^testing.T) {
	b: [8]u8
	sequence_cases := []struct {
		key:      rl.KeyboardKey,
		expected: string,
	} {
		{.ENTER, "\r"},
		{.BACKSPACE, "\x7f"},
		{.TAB, "\t"},
		{.ESCAPE, "\x1b"},
		{.UP, "\x1b[A"},
		{.DOWN, "\x1b[B"},
		{.RIGHT, "\x1b[C"},
		{.LEFT, "\x1b[D"},
		{.HOME, "\x1b[H"},
		{.END, "\x1b[F"},
		{.PAGE_UP, "\x1b[5~"},
		{.PAGE_DOWN, "\x1b[6~"},
		{.INSERT, "\x1b[2~"},
		{.DELETE, "\x1b[3~"},
		{.F1, "\x1bOP"},
		{.F2, "\x1bOQ"},
		{.F3, "\x1bOR"},
		{.F4, "\x1bOS"},
		{.F5, "\x1b[15~"},
		{.F6, "\x1b[17~"},
		{.F7, "\x1b[18~"},
		{.F8, "\x1b[19~"},
		{.F9, "\x1b[20~"},
		{.F10, "\x1b[21~"},
		{.F11, "\x1b[23~"},
		{.F12, "\x1b[24~"},
	}
	for test_case in sequence_cases {
		n, ok := vt_bytes_for_key(test_case.key, false, false, false, nil, b[:])
		testing.expect(t, ok)
		testing.expect_value(t, string(b[:n]), test_case.expected)
	}
}

@(test)
vt_key_map_modifier_precedence :: proc(t: ^testing.T) {
	b: [8]u8
	skip := []rl.KeyboardKey{.A, .TAB}
	n, ok := vt_bytes_for_key(.A, true, true, false, skip, b[:])
	testing.expect(t, !ok)
	testing.expect_value(t, n, 0)
	n, ok = vt_bytes_for_key(.A, true, true, true, skip, b[:])
	testing.expect(t, !ok)
	testing.expect_value(t, n, 0)
	n, ok = vt_bytes_for_key(.TAB, true, true, true, skip, b[:])
	testing.expect(t, ok)
	testing.expect_value(t, string(b[:n]), "\x1b[Z")
	n, ok = vt_bytes_for_key(.UP, true, false, false, nil, b[:])
	testing.expect(t, !ok)
	testing.expect_value(t, n, 0)
	n, ok = vt_bytes_for_key(.UP, true, false, true, nil, b[:])
	testing.expect(t, ok)
	testing.expect_value(t, string(b[:n]), "\x1b[A")
}

@(test)
vt_key_map_short_sequence_buffer_contract :: proc(t: ^testing.T) {
	b: [2]u8
	n, ok := vt_bytes_for_key(.F12, false, false, false, nil, b[:])
	testing.expect(t, ok)
	testing.expect_value(t, n, 2)
	testing.expect_value(t, string(b[:]), "\x1b[")
}

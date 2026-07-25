package term

import "core:testing"
import rl "ingot:gfx"

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
vt_key_map_remaining_contract :: proc(t: ^testing.T) {
	b: [8]u8
	ctrl_cases := []struct {
		key:      rl.KeyboardKey,
		expected: u8,
	}{{.Z, 0x1A}, {.BACKSLASH, 0x1C}, {.RIGHT_BRACKET, 0x1D}, {.GRAVE, 0x1E}}
	for test_case in ctrl_cases {
		n, ok := vt_bytes_for_key(test_case.key, true, false, false, nil, b[:])
		testing.expect(t, ok)
		testing.expect_value(t, n, 1)
		testing.expect_value(t, b[0], test_case.expected)
	}

	sequence_cases := []struct {
		key:      rl.KeyboardKey,
		expected: string,
	} {
		{.ESCAPE, "\x1b"},
		{.DOWN, "\x1b[B"},
		{.RIGHT, "\x1b[C"},
		{.LEFT, "\x1b[D"},
		{.END, "\x1b[F"},
		{.PAGE_DOWN, "\x1b[6~"},
		{.INSERT, "\x1b[2~"},
		{.DELETE, "\x1b[3~"},
		{.F12, "\x1b[24~"},
	}
	for test_case in sequence_cases {
		n, ok := vt_bytes_for_key(test_case.key, false, false, false, nil, b[:])
		testing.expect(t, ok)
		testing.expect_value(t, string(b[:n]), test_case.expected)
	}
}

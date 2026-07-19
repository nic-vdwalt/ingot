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

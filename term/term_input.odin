package term

// term_input - keyboard + clipboard → PTY.
// Call term_handle_input once per frame when the terminal pane is focused.

import "../pty"
import "core:unicode/utf8"
import rl "ingot:gfx"
import "ingot:ui"

TERM_PASTE_MAX_BYTES :: 1024 * 1024
TERM_WRITE_MAX_ATTEMPTS :: 16
TERM_INPUT_CHARACTER_DRAIN_MAX :: rl.CHAR_Q
TERM_INPUT_KEY_DRAIN_MAX :: rl.CHAR_Q
#assert(ui.INPUT_KEY_COUNT <= int(rl.KeyboardKey.KB_MENU) + 1)

@(private = "file")
term_write :: proc(ts: ^Term_Instance, data: []u8) -> bool {
	if ts == nil || len(data) == 0 do return false
	written := 0
	for attempt := 0; attempt < TERM_WRITE_MAX_ATTEMPTS && written < len(data); attempt += 1 {
		n, status := pty.write_bytes(&ts.pty, data[written:])
		if n > 0 do written += n
		if status == .Closed || status == .Failed {
			ts.pty_running = false
			break
		}
		if status == .Would_Block do break
	}
	return written == len(data)
}

// term_handle_input drains all pending key events from Raylib and forwards
// them to the PTY as the appropriate byte sequences.  Returns true when at
// least one byte was written to the PTY so callers can react (e.g. clear a
// text selection).
//
// skip_ctrl_shift lists keys whose Ctrl+Shift chords belong to the host app
// (tab management, shortcuts, ...) and must NOT be forwarded to the shell.
// Shells cannot distinguish shifted control letters anyway.
term_handle_input :: proc(
	ts: ^Term_Instance,
	skip_ctrl_shift: []rl.KeyboardKey = nil,
) -> (
	sent: bool,
) {
	if ts == nil || !ts.pty_running do return

	// --- Printable characters via GetCharPressed() ---
	// Raylib delivers these as Unicode codepoints. We write their UTF-8
	// encoding directly. Control keys (Ctrl+letter) arrive here as codepoints
	// 1-26, so we skip them and handle them via GetKeyPressed() below.
	for _ in 0 ..< TERM_INPUT_CHARACTER_DRAIN_MAX {
		cp := rl.GetCharPressed()
		if cp == 0 do break
		// Skip control characters - handled by the key-press path.
		if cp < 0x20 || cp == 0x7f do continue
		buf, n := utf8.encode_rune(cp)
		sent = term_write(ts, buf[:n]) || sent
	}

	// --- Special keys and control combos via GetKeyPressed() ---
	for _ in 0 ..< TERM_INPUT_KEY_DRAIN_MAX {
		key := rl.GetKeyPressed()
		if key == .KEY_NULL do break

		ctrl := rl.IsKeyDown(.LEFT_CONTROL) || rl.IsKeyDown(.RIGHT_CONTROL)
		shift := rl.IsKeyDown(.LEFT_SHIFT) || rl.IsKeyDown(.RIGHT_SHIFT)
		super := rl.IsKeyDown(.LEFT_SUPER) || rl.IsKeyDown(.RIGHT_SUPER)

		// Cmd+V / Ctrl+Shift+V - paste from clipboard.
		if key == .V && (super || (ctrl && shift)) {
			clip := rl.GetClipboardText()
			if clip != nil {
				paste := transmute([]u8)string(clip)
				if len(paste) <= TERM_PASTE_MAX_BYTES do sent = term_write(ts, paste) || sent
			}
			continue
		}

		// Ctrl+letter - send control codes 0x01–0x1A.
		// Navigation / function keys - VT100/xterm sequences.
		b: [8]u8
		if n, ok := vt_bytes_for_key(key, ctrl, shift, super, skip_ctrl_shift, b[:]); ok {
			sent = term_write(ts, b[:n]) || sent
		}
	}
	// Typing snaps the view back to the live screen.
	if sent {
		ts.sb_view_offset = 0
	}
	return
}

term_handle_ui_input :: proc(
	ts: ^Term_Instance,
	input: ^ui.Ui_Input,
	skip_ctrl_shift: []rl.KeyboardKey = nil,
) -> (
	sent: bool,
) {
	assert(input != nil, "term_handle_ui_input: nil input")
	assert(
		input.character_count >= 0 && input.character_count <= ui.INPUT_CHAR_CAP,
		"term_handle_ui_input: invalid character count",
	)
	if ts == nil || !ts.pty_running do return
	ctrl := ui.input_key_down(input, .LEFT_CONTROL) || ui.input_key_down(input, .RIGHT_CONTROL)
	shift := ui.input_key_down(input, .LEFT_SHIFT) || ui.input_key_down(input, .RIGHT_SHIFT)
	super := ui.input_key_down(input, .LEFT_SUPER) || ui.input_key_down(input, .RIGHT_SUPER)

	if !ctrl && !super {
		count := min(input.character_count, ui.INPUT_CHAR_CAP)
		for cp in input.characters[:count] {
			if cp < 0x20 || cp == 0x7f do continue
			buf, n := utf8.encode_rune(cp)
			sent = term_write(ts, buf[:n]) || sent
		}
	}

	for index in 0 ..< ui.INPUT_KEY_COUNT {
		if !input.keys_pressed[index] && !input.keys_repeat[index] do continue
		key := ui.KeyboardKey(index)
		if key == .V && (super || (ctrl && shift)) {
			paste := ui.input_clipboard(input)
			if len(paste) <= TERM_PASTE_MAX_BYTES {
				sent = term_write(ts, transmute([]u8)paste) || sent
			}
			continue
		}
		b: [8]u8
		if n, ok := vt_bytes_for_key(
			rl.KeyboardKey(key),
			ctrl,
			shift,
			super,
			skip_ctrl_shift,
			b[:],
		); ok {
			sent = term_write(ts, b[:n]) || sent
		}
	}
	if sent do ts.sb_view_offset = 0
	return
}

@(private)
vt_control_byte_for_key :: proc(key: rl.KeyboardKey) -> (value: u8, ok: bool) {
	#partial switch key {
	case .A:
		return 0x01, true
	case .B:
		return 0x02, true
	case .C:
		return 0x03, true
	case .D:
		return 0x04, true
	case .E:
		return 0x05, true
	case .F:
		return 0x06, true
	case .G:
		return 0x07, true
	case .H:
		return 0x08, true
	case .I:
		return 0x09, true
	case .J:
		return 0x0A, true
	case .K:
		return 0x0B, true
	case .L:
		return 0x0C, true
	case .M:
		return 0x0D, true
	case .N:
		return 0x0E, true
	case .O:
		return 0x0F, true
	case .P:
		return 0x10, true
	case .Q:
		return 0x11, true
	case .R:
		return 0x12, true
	case .S:
		return 0x13, true
	case .T:
		return 0x14, true
	case .U:
		return 0x15, true
	case .V:
		return 0x16, true
	case .W:
		return 0x17, true
	case .X:
		return 0x18, true
	case .Y:
		return 0x19, true
	case .Z:
		return 0x1A, true
	case .LEFT_BRACKET:
		return 0x1B, true
	case .BACKSLASH:
		return 0x1C, true
	case .RIGHT_BRACKET:
		return 0x1D, true
	case .GRAVE:
		return 0x1E, true
	}
	return 0, false
}

@(private)
vt_sequence_for_key :: proc(key: rl.KeyboardKey, shift: bool, buf: []u8) -> (int, bool) {
	assert(len(buf) > 0)
	#partial switch key {
	case .ENTER:
		buf[0] = '\r'; return 1, true
	case .BACKSPACE:
		buf[0] = 0x7f; return 1, true
	case .TAB:
		if shift do return copy(buf, "\x1b[Z"), true
		buf[0] = '\t'; return 1, true
	case .ESCAPE:
		buf[0] = 0x1b; return 1, true
	case .UP:
		return copy(buf, "\x1b[A"), true
	case .DOWN:
		return copy(buf, "\x1b[B"), true
	case .RIGHT:
		return copy(buf, "\x1b[C"), true
	case .LEFT:
		return copy(buf, "\x1b[D"), true
	case .HOME:
		return copy(buf, "\x1b[H"), true
	case .END:
		return copy(buf, "\x1b[F"), true
	case .PAGE_UP:
		return copy(buf, "\x1b[5~"), true
	case .PAGE_DOWN:
		return copy(buf, "\x1b[6~"), true
	case .INSERT:
		return copy(buf, "\x1b[2~"), true
	case .DELETE:
		return copy(buf, "\x1b[3~"), true
	case .F1:
		return copy(buf, "\x1bOP"), true
	case .F2:
		return copy(buf, "\x1bOQ"), true
	case .F3:
		return copy(buf, "\x1bOR"), true
	case .F4:
		return copy(buf, "\x1bOS"), true
	case .F5:
		return copy(buf, "\x1b[15~"), true
	case .F6:
		return copy(buf, "\x1b[17~"), true
	case .F7:
		return copy(buf, "\x1b[18~"), true
	case .F8:
		return copy(buf, "\x1b[19~"), true
	case .F9:
		return copy(buf, "\x1b[20~"), true
	case .F10:
		return copy(buf, "\x1b[21~"), true
	case .F11:
		return copy(buf, "\x1b[23~"), true
	case .F12:
		return copy(buf, "\x1b[24~"), true
	}
	return 0, false
}

// vt_bytes_for_key maps a single key event to the VT byte sequence a terminal
// expects. Pure: no raylib input, no clipboard. Writes into buf and returns the
// byte count; ok=false means "emit nothing" (unmapped key, or a host-app
// Ctrl+Shift chord listed in skip_ctrl_shift). Paste (Cmd/Ctrl+Shift+V) is NOT
// handled here - the caller intercepts it first because it needs the clipboard.
@(private)
vt_bytes_for_key :: proc(
	key: rl.KeyboardKey,
	ctrl, shift, super: bool,
	skip_ctrl_shift: []rl.KeyboardKey,
	buf: []u8,
) -> (
	n: int,
	ok: bool,
) {
	assert(len(buf) > 0)
	if ctrl && !super {
		if shift {
			for sk in skip_ctrl_shift do if key == sk do return 0, false
		}
		value, mapped := vt_control_byte_for_key(key)
		if !mapped do return 0, false
		buf[0] = value
		return 1, true
	}
	return vt_sequence_for_key(key, shift, buf)
}

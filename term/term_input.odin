package term

// term_input — keyboard + clipboard → PTY.
// Call term_handle_input once per frame when the terminal pane is focused.

import "core:unicode/utf8"
import rl "vendor:raylib"
import "../pty"

// term_handle_input drains all pending key events from Raylib and forwards
// them to the PTY as the appropriate byte sequences.  Returns true when at
// least one byte was written to the PTY so callers can react (e.g. clear a
// text selection).
//
// skip_ctrl_shift lists keys whose Ctrl+Shift chords belong to the host app
// (tab management, shortcuts, ...) and must NOT be forwarded to the shell.
// Shells cannot distinguish shifted control letters anyway.
term_handle_input :: proc(ts: ^Term_Instance, skip_ctrl_shift: []rl.KeyboardKey = nil) -> (sent: bool) {
	if ts == nil || !ts.pty_running do return

	// --- Printable characters via GetCharPressed() ---
	// Raylib delivers these as Unicode codepoints. We write their UTF-8
	// encoding directly. Control keys (Ctrl+letter) arrive here as codepoints
	// 1-26, so we skip them and handle them via GetKeyPressed() below.
	for {
		cp := rl.GetCharPressed()
		if cp == 0 do break
		// Skip control characters — handled by the key-press path.
		if cp < 0x20 || cp == 0x7f do continue
		buf, n := utf8.encode_rune(cp)
		pty.write_bytes(&ts.pty, buf[:n])
		sent = true
	}

	// --- Special keys and control combos via GetKeyPressed() ---
	for {
		key := rl.GetKeyPressed()
		if key == .KEY_NULL do break

		ctrl  := rl.IsKeyDown(.LEFT_CONTROL) || rl.IsKeyDown(.RIGHT_CONTROL)
		shift := rl.IsKeyDown(.LEFT_SHIFT)   || rl.IsKeyDown(.RIGHT_SHIFT)
		super := rl.IsKeyDown(.LEFT_SUPER)   || rl.IsKeyDown(.RIGHT_SUPER)

		// Cmd+V / Ctrl+Shift+V — paste from clipboard.
		if key == .V && (super || (ctrl && shift)) {
			clip := rl.GetClipboardText()
			if clip != nil {
				pty.write_string(&ts.pty, string(clip))
				sent = true
			}
			continue
		}

		// Ctrl+letter — send control codes 0x01–0x1A.
		if ctrl && !super {
			// Host-app Ctrl+Shift chords are consumed by the app's shortcut
			// handling and never forwarded.
			if shift {
				skipped := false
				for sk in skip_ctrl_shift {
					if key == sk {
						skipped = true
						break
					}
				}
				if skipped do continue
			}
			#partial switch key {
			case .A: pty.write_byte(&ts.pty, 0x01); sent = true
			case .B: pty.write_byte(&ts.pty, 0x02); sent = true
			case .C: pty.write_byte(&ts.pty, 0x03); sent = true
			case .D: pty.write_byte(&ts.pty, 0x04); sent = true
			case .E: pty.write_byte(&ts.pty, 0x05); sent = true
			case .F: pty.write_byte(&ts.pty, 0x06); sent = true
			case .G: pty.write_byte(&ts.pty, 0x07); sent = true
			case .H: pty.write_byte(&ts.pty, 0x08); sent = true
			case .I: pty.write_byte(&ts.pty, 0x09); sent = true // Tab
			case .J: pty.write_byte(&ts.pty, 0x0A); sent = true
			case .K: pty.write_byte(&ts.pty, 0x0B); sent = true
			case .L: pty.write_byte(&ts.pty, 0x0C); sent = true
			case .M: pty.write_byte(&ts.pty, 0x0D); sent = true // CR
			case .N: pty.write_byte(&ts.pty, 0x0E); sent = true
			case .O: pty.write_byte(&ts.pty, 0x0F); sent = true
			case .P: pty.write_byte(&ts.pty, 0x10); sent = true
			case .Q: pty.write_byte(&ts.pty, 0x11); sent = true
			case .R: pty.write_byte(&ts.pty, 0x12); sent = true
			case .S: pty.write_byte(&ts.pty, 0x13); sent = true
			case .T: pty.write_byte(&ts.pty, 0x14); sent = true
			case .U: pty.write_byte(&ts.pty, 0x15); sent = true
			case .V: pty.write_byte(&ts.pty, 0x16); sent = true
			case .W: pty.write_byte(&ts.pty, 0x17); sent = true
			case .X: pty.write_byte(&ts.pty, 0x18); sent = true
			case .Y: pty.write_byte(&ts.pty, 0x19); sent = true
			case .Z: pty.write_byte(&ts.pty, 0x1A); sent = true
			case .LEFT_BRACKET:  pty.write_byte(&ts.pty, 0x1B); sent = true // Ctrl+[  → ESC
			case .BACKSLASH:     pty.write_byte(&ts.pty, 0x1C); sent = true
			case .RIGHT_BRACKET: pty.write_byte(&ts.pty, 0x1D); sent = true
			case .GRAVE:         pty.write_byte(&ts.pty, 0x1E); sent = true
			}
			continue
		}

		// Navigation / function keys — VT100/xterm sequences.
		#partial switch key {
		case .ENTER:     pty.write_byte(&ts.pty, '\r');            sent = true
		case .BACKSPACE: pty.write_byte(&ts.pty, 0x7f);            sent = true
		case .TAB:
			if shift {
				pty.write_string(&ts.pty, "\x1b[Z")
			} else {
				pty.write_byte(&ts.pty, '\t')
			}
			sent = true
		case .ESCAPE:    pty.write_byte(&ts.pty, 0x1b);            sent = true
		case .UP:        pty.write_string(&ts.pty, "\x1b[A");      sent = true
		case .DOWN:      pty.write_string(&ts.pty, "\x1b[B");      sent = true
		case .RIGHT:     pty.write_string(&ts.pty, "\x1b[C");      sent = true
		case .LEFT:      pty.write_string(&ts.pty, "\x1b[D");      sent = true
		case .HOME:      pty.write_string(&ts.pty, "\x1b[H");      sent = true
		case .END:       pty.write_string(&ts.pty, "\x1b[F");      sent = true
		case .PAGE_UP:   pty.write_string(&ts.pty, "\x1b[5~");     sent = true
		case .PAGE_DOWN: pty.write_string(&ts.pty, "\x1b[6~");     sent = true
		case .INSERT:    pty.write_string(&ts.pty, "\x1b[2~");     sent = true
		case .DELETE:    pty.write_string(&ts.pty, "\x1b[3~");     sent = true
		case .F1:        pty.write_string(&ts.pty, "\x1bOP");      sent = true
		case .F2:        pty.write_string(&ts.pty, "\x1bOQ");      sent = true
		case .F3:        pty.write_string(&ts.pty, "\x1bOR");      sent = true
		case .F4:        pty.write_string(&ts.pty, "\x1bOS");      sent = true
		case .F5:        pty.write_string(&ts.pty, "\x1b[15~");    sent = true
		case .F6:        pty.write_string(&ts.pty, "\x1b[17~");    sent = true
		case .F7:        pty.write_string(&ts.pty, "\x1b[18~");    sent = true
		case .F8:        pty.write_string(&ts.pty, "\x1b[19~");    sent = true
		case .F9:        pty.write_string(&ts.pty, "\x1b[20~");    sent = true
		case .F10:       pty.write_string(&ts.pty, "\x1b[21~");    sent = true
		case .F11:       pty.write_string(&ts.pty, "\x1b[23~");    sent = true
		case .F12:       pty.write_string(&ts.pty, "\x1b[24~");    sent = true
		}
	}
	// Typing snaps the view back to the live screen.
	if sent {
		ts.sb_view_offset = 0
	}
	return
}

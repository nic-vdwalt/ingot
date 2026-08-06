#+build linux, darwin
package term

// Round-trip test for term_start_argv: run a real command (no shell) on a
// PTY, pump its output into libvterm, and verify both the echoed text on the
// screen and the reaped exit code.

import "core:testing"
import "core:time"
import lv "ingot:libvterm"
import "ingot:pty"

when !pty.INGOT_PTY_SIM {

	@(private = "file")
	screen_row_text :: proc(ts: ^Term_Instance, row: int, buf: []u8) -> string {
		n := 0
		for col in 0 ..< int(ts.cols) {
			if n >= len(buf) do break
			cell: lv.VTerm_Screen_Cell
			pos := lv.VTerm_Pos {
				row = i32(row),
				col = i32(col),
			}
			lv.vterm_screen_get_cell(ts.screen, pos, &cell)
			cp := cell.chars[0]
			if cp == 0 || cp == 0xFFFFFFFF do cp = ' '
			if cp < 0x80 {
				buf[n] = u8(cp)
				n += 1
			}
		}
		return string(buf[:n])
	}

	@(test)
	spawn_argv_runs_command_and_reports_exit :: proc(t: ^testing.T) {
		argv := []cstring{"/bin/echo", "argv-round-trip"}
		ts := term_start_argv(argv, ".", 80, 24)
		testing.expect(t, ts != nil, "term_start_argv failed")
		if ts == nil do return
		defer term_destroy(ts)

		for _ in 0 ..< 500 {
			_ = term_pump(ts)
			if !ts.pty_running do break
			time.sleep(10 * time.Millisecond)
		}
		for _ in 0 ..< 10 {
			_ = term_pump(ts)
			time.sleep(time.Millisecond)
		}
		testing.expect(t, !ts.pty_running, "child should reach EOF")

		exited, code := term_child_poll(ts)
		testing.expect(t, exited, "child should be reaped")
		testing.expect_value(t, code, 0)

		buf: [128]u8
		row0 := screen_row_text(ts, 0, buf[:])
		found := false
		for i in 0 ..< len(row0) {
			if i + len("argv-round-trip") > len(row0) do break
			if row0[i:i + len("argv-round-trip")] == "argv-round-trip" {
				found = true
				break
			}
		}
		testing.expect(t, found, "echoed argv text should appear on the screen")
	}

	@(test)
	spawn_argv_rejects_empty_argv :: proc(t: ^testing.T) {
		_, ok := pty.spawn_argv(nil, 80, 24)
		testing.expect(t, !ok, "empty argv must fail")
	}
}
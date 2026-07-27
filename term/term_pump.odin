package term

// term_pump — per-frame PTY drain → libvterm write.
// Call every frame from the host app's main loop for ALL terminal instances
// (not just the visible one) so background shells keep their emulator state
// current and switching views shows the latest screen instead of a
// fast-forward replay of the backlog.

import lv "../libvterm"
import "../pty"
import "core:c"
import "core:sync"

// Maximum buffer-fulls drained per term_pump call. Bounds worst-case frame
// time while letting a large backlog (e.g. `cat` of a big file) catch up at
// up to 16 × 64 KiB = 1 MiB per frame instead of one buffer per frame.
TERM_PUMP_MAX_BUFS :: 16

// _utf8_complete_prefix returns the length of the longest prefix of buf that
// does not end in an incomplete multi-byte UTF-8 sequence.  At most the last
// 3 bytes can belong to an unfinished sequence (a 4-byte sequence missing
// its final byte).
@(private)
_utf8_complete_prefix :: proc(buf: []u8) -> int {
	n := len(buf)
	// The result is always a prefix length in [0, n]. At most the last 3 bytes
	// can be withheld (an unfinished 4-byte sequence), so any early return is
	// still within bounds.
	i := n - 1
	for _ in 0 ..< 3 {
		if i < 0 do break
		b := buf[i]
		if b < 0x80 {
			// ASCII — the tail is complete.
			return n
		}
		if b >= 0xC0 {
			// Lead byte at i; how many bytes does the sequence need?
			need := 2
			if b >= 0xF0 {
				need = 4
			} else if b >= 0xE0 {
				need = 3
			}
			if n - i < need {
				return i // incomplete: hold back from the lead byte
			}
			return n
		}
		// Continuation byte — keep scanning backwards.
		i -= 1
	}
	return n
}

// _term_ingest feeds ts.read_buf[:total] to the emulator, holding back any
// incomplete trailing UTF-8 sequence (unless eof) so a multi-byte character
// is never split across vterm_input_write calls. Extracted from term_pump so
// hostile-input fuzzing drives the production ingestion path directly.
@(private)
_term_ingest :: proc(ts: ^Term_Instance, total: int, eof: bool) {
	assert(ts != nil)
	assert(total >= 0)
	assert(total <= len(ts.read_buf))
	assert(ts.utf8_hold_len >= 0)
	assert(ts.utf8_hold_len <= 3)
	if total <= 0 do return
	complete := total
	if !eof {
		complete = _utf8_complete_prefix(ts.read_buf[:total])
		// The complete prefix is a prefix of total, never longer.
		// Split so a failure points at the exact bound.
		assert(complete >= 0)
		assert(complete <= total)
		tail := total - complete
		if tail > 0 && tail <= len(ts.utf8_hold) {
			copy(ts.utf8_hold[:tail], ts.read_buf[complete:total])
			ts.utf8_hold_len = tail
		} else {
			// Invalid or oversized tail — feed everything as-is.
			complete = total
		}
	}
	if complete > 0 {
		assert(complete <= len(ts.read_buf))
		lv.vterm_input_write(ts.vt, raw_data(ts.read_buf[:]), c.size_t(complete))
	}
	assert(ts.utf8_hold_len >= 0)
	assert(ts.utf8_hold_len <= 3)
}

// term_pump reads all available PTY output and feeds it to the terminal
// emulator.  Sets ts.pty_running = false on EOF.  Title updates happen
// automatically via the settermprop callback registered in term_start.
//
// libvterm does not preserve UTF-8 decoder state across vterm_input_write
// calls: a multi-byte sequence split across two reads is rendered as one or
// more U+FFFD replacement cells, shifting the rest of the row.  To prevent
// that, any incomplete trailing sequence is held back and prepended to the
// next read.
//
// Returns the number of PTY bytes consumed this call so callers can detect
// output on background tabs (unread badge).
term_pump :: proc(ts: ^Term_Instance) -> (bytes_read: int) {
	if ts == nil || !ts.pty_running do return 0

	when pty.INGOT_PTY_SIM {
		for _ in 0 ..< TERM_PUMP_MAX_BUFS {
			hold := ts.utf8_hold_len
			assert(hold >= 0)
			assert(hold <= 3)
			assert(hold < len(ts.read_buf))
			copy(ts.read_buf[:hold], ts.utf8_hold[:hold])
			data, eof := pty.drain(&ts.pty, ts.read_buf[hold:])
			total := hold + len(data)
			assert(total <= len(ts.read_buf))
			ts.utf8_hold_len = 0
			_term_ingest(ts, total, eof)
			bytes_read += len(data)
			if eof {
				ts.pty_running = false
				return
			}
			if total < len(ts.read_buf) do break
		}
	} else {
		for _ in 0 ..< TERM_PUMP_MAX_BUFS {
			sync.mutex_lock(&ts.output_mutex)
			assert(ts.output_head >= 0)
			assert(ts.output_head < TERM_OUTPUT_QUEUE_CAP)
			assert(ts.output_count >= 0)
			assert(ts.output_count <= TERM_OUTPUT_QUEUE_CAP)
			if ts.output_count == 0 {
				eof := ts.output_eof
				sync.mutex_unlock(&ts.output_mutex)
				if eof {
					ts.pty_running = false
				}
				break
			}
			chunk := &ts.output_queue[ts.output_head]
			n := chunk.len
			assert(n >= 0)
			assert(n <= len(chunk.data))
			assert(ts.utf8_hold_len >= 0)
			assert(ts.utf8_hold_len + n <= len(ts.read_buf))
			copy(ts.read_buf[ts.utf8_hold_len:], chunk.data[:n])
			chunk.len = 0
			ts.output_head = (ts.output_head + 1) % TERM_OUTPUT_QUEUE_CAP
			ts.output_count -= 1
			assert(ts.output_head >= 0)
			assert(ts.output_head < TERM_OUTPUT_QUEUE_CAP)
			assert(ts.output_count >= 0)
			eof := ts.output_eof && ts.output_count == 0
			sync.mutex_unlock(&ts.output_mutex)

			hold := ts.utf8_hold_len
			copy(ts.read_buf[:hold], ts.utf8_hold[:hold])
			ts.utf8_hold_len = 0
			_term_ingest(ts, hold + n, eof)
			bytes_read += n
			if eof {
				ts.pty_running = false
				break
			}
		}
	}
	assert(bytes_read >= 0)
	assert(bytes_read <= TERM_PUMP_MAX_BUFS * len(ts.read_buf))
	return
}

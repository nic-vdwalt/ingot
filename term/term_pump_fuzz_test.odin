#+build !js
package term

// Fuzz for the paths the vterm fuzzers bypass: term_pump's real drain/EOF
// loop, term_resize's public bookkeeping (cols/rows + PTY + vterm resize),
// and resizes interleaved with a split UTF-8 hold prefix. Requires the
// scripted PTY (-define:INGOT_PTY_SIM=true, pty/pty_sim.odin); the test
// no-ops without it so `scripts/test.sh` needs the define to gain coverage
// (it passes it — see scripts/test.sh). Iterations scale with
// -define:INGOT_FUZZ_ITER for fuzz/run.sh term.

import "core:c"
import "core:log"
import "core:testing"
import "core:time"
import lv "../libvterm"
import "ingot:pty"
import "ingot:testx"

// Used only under `when pty.INGOT_PTY_SIM`; anchor for plain checks.
_ :: c
_ :: lv
_ :: testx
_ :: time

TERM_PUMP_FUZZ_ITER :: #config(INGOT_FUZZ_ITER, 300)

@(test)
term_pump_resize_fuzz :: proc(t: ^testing.T) {
	when pty.INGOT_PTY_SIM {
		seed := u64(time.now()._nsec)
		log.infof("term_pump_fuzz seed=%d iterations=%d", seed, TERM_PUMP_FUZZ_ITER)
		p := testx.prng_make(seed)

		for i in 0 ..< TERM_PUMP_FUZZ_ITER {
			ts := new(Term_Instance)
			cols := u16(testx.int_range(&p, 2, 200))
			rows := u16(testx.int_range(&p, 2, 80))
			testing.expect(t, term_init_emulator(ts, cols, rows))
			ts.pty.master_fd = -1 // no real fd: pty.resize must no-op
			ts.pty_running = true

			// Hostile document with multi-byte runes so chunk splits land
			// mid-sequence and exercise the UTF-8 hold protocol; sometimes a
			// giant tape to force the multi-buffer pump path.
			maximum := 4096
			if testx.int_range(&p, 0, 20) == 0 do maximum = 3 * len(ts.read_buf)
			doc := fuzz_vt_document(&p, maximum)
			eof_now := testx.int_range(&p, 0, 3) == 0
			pty.pty_sim_load(doc, testx.next_u64(&p), eof_now)

			ops := testx.int_range(&p, 2, 12)
			for _ in 0 ..< ops {
				switch testx.int_range(&p, 0, 5) {
				case 0, 1, 2:
					_ = term_pump(ts)
				case 3:
					// Public resize path (bookkeeping + vterm), including
					// no-op same-size calls, mid-tape — i.e. potentially
					// between the halves of a split UTF-8 sequence.
					term_resize(
						ts,
						u16(testx.int_range(&p, 2, 200)),
						u16(testx.int_range(&p, 2, 80)),
					)
				case 4:
					ts.sb_view_offset = testx.int_range(&p, 0, len(ts.sb_lines) + 1)
				}

				// Hold prefix: at most 3 bytes and never after EOF ingest.
				testing.expect(t, ts.utf8_hold_len >= 0 && ts.utf8_hold_len <= 3,
					"utf8 hold length out of range")
				// Resize bookkeeping must agree with the emulator's real grid —
				// renderers size their cell loops from ts.cols/rows while cell
				// reads hit vterm; divergence reads out of grid bounds.
				vrows, vcols: c.int
				lv.vterm_get_size(ts.vt, &vrows, &vcols)
				testing.expect(t, int(ts.cols) == int(vcols), "ts.cols diverged from vterm grid")
				testing.expect(t, int(ts.rows) == int(vrows), "ts.rows diverged from vterm grid")
				fuzz_vt_check_invariants(t, ts)
			}

			// Drain to completion: EOF must stop the pump exactly once,
			// within a bounded number of calls — an unbounded loop here
			// would turn a wedged pump (e.g. a hold prefix that is re-held
			// forever) into a test hang instead of a failure.
			if eof_now {
				for _ in 0 ..< 1000 {
					if !ts.pty_running do break
					_ = term_pump(ts)
				}
				testing.expect(t, !ts.pty_running, "pump did not reach EOF within bound (wedged)")
				if !ts.pty_running {
					testing.expect(t, term_pump(ts) == 0, "pump read after EOF")
				}
			}

			// doc is temp-allocated (fuzz_vt_document); freed with the arena.
			term_free_emulator(ts)
			free(ts)
			free_all(context.temp_allocator)
		}
	} else {
		log.info("term_pump_fuzz skipped (build with -define:INGOT_PTY_SIM=true)")
	}
}

// Simulated PTY byte source (-define:INGOT_PTY_SIM=true). Replaces
// read_bytes/drain with a scripted tape so term_pump's real drain loop,
// EOF handling, and UTF-8 hold-prefix logic can be fuzzed without spawning
// a shell. Single-threaded (term/pty have no threads).
package pty

INGOT_PTY_SIM :: #config(INGOT_PTY_SIM, false)

when INGOT_PTY_SIM {

	@(private = "file") Pty_Sim :: struct {
		tape:       []u8, // caller-owned; valid until the next load
		pos:        int,
		chunk_seed: u64, // deterministic chunk sizing
		eof_after:  bool, // report EOF once the tape is exhausted
	}

	@(private = "file") g_pty_sim: Pty_Sim

	// pty_sim_load installs a byte tape. `tape` must outlive the pump calls.
	pty_sim_load :: proc(tape: []u8, chunk_seed: u64, eof_after: bool) {
		g_pty_sim = {tape = tape, chunk_seed = chunk_seed, eof_after = eof_after}
	}

	// pty_sim_exhausted reports whether the whole tape has been consumed.
	pty_sim_exhausted :: proc() -> bool {
		return g_pty_sim.pos >= len(g_pty_sim.tape)
	}

	@(private = "file")
	sim_chunk :: proc(limit: int) -> int {
		g_pty_sim.chunk_seed ~= g_pty_sim.chunk_seed << 13
		g_pty_sim.chunk_seed ~= g_pty_sim.chunk_seed >> 7
		g_pty_sim.chunk_seed ~= g_pty_sim.chunk_seed << 17
		// Bias toward small chunks (UTF-8 split points) but occasionally
		// fill the whole buffer (multi-buffer pump path).
		r := g_pty_sim.chunk_seed * 0x2545F4914F6CDD1D
		if r % 5 == 0 do return limit
		return int(r % 7) + 1
	}

	read_bytes :: proc(p: ^Pty, buf: []u8) -> (n: int, eof: bool) {
		remaining := len(g_pty_sim.tape) - g_pty_sim.pos
		if remaining <= 0 {
			return 0, g_pty_sim.eof_after
		}
		n = min(min(sim_chunk(len(buf)), len(buf)), remaining)
		copy(buf[:n], g_pty_sim.tape[g_pty_sim.pos:g_pty_sim.pos + n])
		g_pty_sim.pos += n
		return n, false
	}

	drain :: proc(p: ^Pty, buf: []u8) -> (data: []u8, eof: bool) {
		total := 0
		for total < len(buf) {
			n, e := read_bytes(p, buf[total:])
			total += n
			if e do return buf[:total], true
			if n == 0 do break
		}
		return buf[:total], false
	}
}

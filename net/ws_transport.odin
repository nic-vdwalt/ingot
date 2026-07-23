#+build !js
// WebSocket transport seam. The worker thread (ws.odin) performs all socket
// I/O through the ws_net_* procs below so a compile-gated simulated
// transport (-define:INGOT_WS_SIM=true, ws_sim.odin) can replace the network
// while keeping the REAL worker thread, mutexes, atomics, and backoff waits
// — the reconnect fuzzer (fuzz/wsreconn) is thereby both a state-machine
// fuzzer (ASan) and a race-detector target (TSan). Zero-cost passthroughs in
// normal builds.
package ingotnet

import cnet "core:net"
import "core:time"

INGOT_WS_SIM :: #config(INGOT_WS_SIM, false)

// WS_TIME_SCALE compresses backoff/liveness waits so a full simulated
// reconnect cycle (dial retries + WS_RECONNECT_WAIT + WS_DEAD_AFTER) runs in
// about a millisecond instead of tens of seconds. 1.0 (identity) on real
// builds — the constant folds away.
when INGOT_WS_SIM {
	WS_TIME_SCALE :: 0.001
} else {
	WS_TIME_SCALE :: 1.0
}

// ws_scaled applies WS_TIME_SCALE to a duration, with a 1ms floor in sim
// mode so cond_wait timeouts stay meaningful to the scheduler.
ws_scaled :: proc(d: time.Duration) -> time.Duration {
	when INGOT_WS_SIM {
		s := time.Duration(f64(d) * WS_TIME_SCALE)
		return max(s, time.Millisecond)
	} else {
		return d
	}
}

// Ws_Net_Err collapses platform network errors to what the worker's control
// flow distinguishes: timeout (liveness probe path) vs everything else.
Ws_Net_Err :: enum u8 {
	None,
	Timeout,
	Other,
}

when !INGOT_WS_SIM {
	// Native passthroughs to core:net.

	ws_net_resolve :: proc(host: string, port: int) -> (cnet.Endpoint, bool) {
		// Fast path: literal IP address.
		if addr, ok := cnet.parse_ip4_address(host); ok {
			return cnet.Endpoint{address = addr, port = port}, true
		}
		// DNS lookup.
		ep, err := cnet.resolve_ip4(host)
		if err != nil {
			return {}, false
		}
		ep.port = port
		return ep, true
	}

	ws_net_dial :: proc(ep: cnet.Endpoint) -> (cnet.TCP_Socket, bool) {
		sock, err := cnet.dial_tcp(ep)
		return sock, err == nil
	}

	ws_net_send :: proc(sock: cnet.TCP_Socket, data: []u8) -> (int, Ws_Net_Err) {
		n, err := cnet.send(sock, data)
		if err != nil do return n, .Other
		return n, .None
	}

	ws_net_recv :: proc(sock: cnet.TCP_Socket, buf: []u8) -> (int, Ws_Net_Err) {
		n, err := cnet.recv(sock, buf)
		if err != nil {
			if err == .Timeout || err == .Would_Block do return n, .Timeout
			return n, .Other
		}
		return n, .None
	}

	ws_net_close :: proc(sock: cnet.TCP_Socket) {
		cnet.close(sock)
	}

	ws_net_set_recv_timeout :: proc(sock: cnet.TCP_Socket, d: time.Duration) {
		_ = cnet.set_option(sock, .Receive_Timeout, d)
	}
}

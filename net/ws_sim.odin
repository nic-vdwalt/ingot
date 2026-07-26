#+build !js
// Simulated WebSocket transport (-define:INGOT_WS_SIM=true). Replaces the
// ws_net_* seam (ws_transport.odin) with a deterministic scripted fake so
// the reconnect fuzzer can drive the REAL worker thread through dial
// failures, handshake garbage, frame streams, mid-frame cuts, server
// closes, and PING starvation — no sockets, no ports, reproducible from a
// seed.
//
// Threading contract: the script tape is loaded by the harness BEFORE
// ws_start_connect (happens-before via thread.start) and consumed only by
// the worker thread afterwards; the sim's cross-thread bits (handshake key
// capture from ws_send_frame's PING/main-thread sends) sit behind sim_mutex.
package ingotnet

import cnet "core:net"
import "core:strings"
import "core:sync"
import "core:time"

// Used only under `when INGOT_WS_SIM`; anchor for plain checks.
_ :: time
_ :: strings
_ :: sync
_ :: cnet

when INGOT_WS_SIM {

	// One scripted transport event, consumed in order per dial attempt /
	// recv call. The tape wraps: when exhausted, further recvs report
	// .Timeout until WS_DEAD_AFTER declares the connection dead — so every
	// tape terminates.
	Ws_Sim_Event :: enum u8 {
		Dial_Fail, // dial refused
		Handshake_Garbage, // 101 never arrives (junk response)
		Handshake_Cut, // handshake recv reports error
		Frame_Text, // one clean text frame
		Frame_Binary, // one clean binary frame
		Frame_Ping, // server PING (worker must PONG)
		Frame_Split, // text frame delivered in two recv calls
		Frame_Fragmented, // one text message as TEXT(FIN=0) + CONTINUATION(FIN=1)
		Frame_Burst, // many text frames, enough to overflow recv_queue
		Frame_Garbage, // bare continuation frame (parse ok, reassembly rejects -> disconnect)
		Server_Close, // clean CLOSE frame
		Cut, // recv error mid-connection
		Timeout, // recv timeout (PING probe path)
	}

	MAX_SIM_EVENTS :: 256
	WS_SIM_BURST_FRAMES :: WS_MAX_QUEUED_MESSAGES + 17

	@(private = "file")
	Ws_Sim :: struct {
		tape:            [MAX_SIM_EVENTS]Ws_Sim_Event,
		tape_len:        int,
		tape_pos:        int, // worker-thread only after start
		payload_seed:    u64, // deterministic payload generation
		pending_key:     [64]u8, // handshake key captured from the upgrade request
		pending_key_len: int,
		split_tail:      [128]u8, // second half of a Frame_Split
		split_tail_len:  int,
		handle_seq:      i64,
		frames_served:   int, // atomic; harness-side observability
		burst_remaining: int, // worker-thread only; Frame_Burst expansion
		mutex:           sync.Mutex,
	}

	@(private = "file")
	g_ws_sim: Ws_Sim

	// ws_sim_load installs a script tape. Call before ws_start_connect and
	// never while a worker is running.
	ws_sim_load :: proc(events: []Ws_Sim_Event, payload_seed: u64) {
		assert(len(events) <= MAX_SIM_EVENTS, "ws_sim_load: tape too long")
		sync.mutex_lock(&g_ws_sim.mutex)
		defer sync.mutex_unlock(&g_ws_sim.mutex)
		copy(g_ws_sim.tape[:], events)
		g_ws_sim.tape_len = len(events)
		g_ws_sim.tape_pos = 0
		g_ws_sim.payload_seed = payload_seed
		g_ws_sim.split_tail_len = 0
		g_ws_sim.pending_key_len = 0
		g_ws_sim.burst_remaining = 0
		sync.atomic_store(&g_ws_sim.frames_served, 0)
	}

	// ws_sim_frames_served reports clean frames delivered (harness checks
	// drain counts against it).
	ws_sim_frames_served :: proc() -> int {
		return sync.atomic_load(&g_ws_sim.frames_served)
	}

	@(private = "file")
	sim_next :: proc() -> (Ws_Sim_Event, bool) {
		sync.mutex_lock(&g_ws_sim.mutex)
		defer sync.mutex_unlock(&g_ws_sim.mutex)
		if g_ws_sim.tape_pos >= g_ws_sim.tape_len do return .Timeout, false
		ev := g_ws_sim.tape[g_ws_sim.tape_pos]
		g_ws_sim.tape_pos += 1
		return ev, true
	}

	@(private = "file")
	sim_rand :: proc() -> u64 {
		sync.mutex_lock(&g_ws_sim.mutex)
		defer sync.mutex_unlock(&g_ws_sim.mutex)
		g_ws_sim.payload_seed ~= g_ws_sim.payload_seed << 13
		g_ws_sim.payload_seed ~= g_ws_sim.payload_seed >> 7
		g_ws_sim.payload_seed ~= g_ws_sim.payload_seed << 17
		return g_ws_sim.payload_seed * 0x2545F4914F6CDD1D
	}

	// sim_server_frame writes an unmasked server frame (small payloads only)
	// into buf; returns the byte count. fin=false emits a fragment (used by
	// Frame_Fragmented to exercise the recv loop's reassembly).
	@(private = "file")
	sim_server_frame :: proc(buf: []u8, opcode: u8, payload: []u8, fin := true) -> int {
		assert(len(payload) < 126, "sim_server_frame: small payloads only")
		assert(len(buf) >= 2 + len(payload), "sim_server_frame: buffer too small")
		buf[0] = (0x80 if fin else 0x00) | opcode
		buf[1] = u8(len(payload)) // no mask bit (server frames are unmasked)
		copy(buf[2:], payload)
		return 2 + len(payload)
	}

	ws_net_resolve :: proc(host: string, port: int) -> (cnet.Endpoint, bool) {
		return {}, true // resolution always succeeds in sim
	}

	ws_net_dial :: proc(ep: cnet.Endpoint) -> (cnet.TCP_Socket, bool) {
		ev, _ := sim_next()
		if ev == .Dial_Fail do return {}, false
		// Any non-Dial_Fail event is "connection accepted"; the event is
		// consumed either way (the tape models the server's behavior tick
		// by tick). Rewind non-dial events so the handshake sees them.
		if ev != .Dial_Fail {
			sync.mutex_lock(&g_ws_sim.mutex)
			g_ws_sim.tape_pos = max(g_ws_sim.tape_pos - 1, 0)
			sync.mutex_unlock(&g_ws_sim.mutex)
		}
		sync.mutex_lock(&g_ws_sim.mutex)
		g_ws_sim.handle_seq += 1
		h := g_ws_sim.handle_seq
		sync.mutex_unlock(&g_ws_sim.mutex)
		return cnet.TCP_Socket(h), true
	}

	ws_net_send :: proc(sock: cnet.TCP_Socket, data: []u8) -> (int, Ws_Net_Err) {
		// Capture the Sec-WebSocket-Key from the upgrade request so the
		// simulated 101 can carry a valid Accept. Worker or main thread.
		s := string(data)
		if key_at := strings.index(s, "Sec-WebSocket-Key: "); key_at >= 0 {
			rest := s[key_at + len("Sec-WebSocket-Key: "):]
			if end := strings.index(rest, "\r\n"); end > 0 && end < 64 {
				sync.mutex_lock(&g_ws_sim.mutex)
				copy(g_ws_sim.pending_key[:], rest[:end])
				g_ws_sim.pending_key_len = end
				sync.mutex_unlock(&g_ws_sim.mutex)
			}
		}
		return len(data), .None // sink everything (PONGs, texts, CLOSE)
	}

	@(private)
	sim_recv_pending_burst :: proc(buf: []u8) -> (int, Ws_Net_Err, bool) {
		if g_ws_sim.burst_remaining <= 0 do return 0, .None, false
		payload: [8]u8
		for index in 0 ..< len(payload) do payload[index] = u8('a' + (sim_rand() % 26))
		g_ws_sim.burst_remaining -= 1
		sync.atomic_add(&g_ws_sim.frames_served, 1)
		return sim_server_frame(buf, WS_OP_TEXT, payload[:]), .None, true
	}

	@(private)
	sim_recv_split_tail :: proc(buf: []u8) -> (int, Ws_Net_Err, bool) {
		sync.mutex_lock(&g_ws_sim.mutex)
		defer sync.mutex_unlock(&g_ws_sim.mutex)
		if g_ws_sim.split_tail_len <= 0 do return 0, .None, false
		count := copy(buf, g_ws_sim.split_tail[:g_ws_sim.split_tail_len])
		g_ws_sim.split_tail_len = 0
		return count, .None, true
	}

	@(private)
	sim_recv_handshake :: proc(buf: []u8) -> (int, Ws_Net_Err, bool) {
		sync.mutex_lock(&g_ws_sim.mutex)
		key_len := g_ws_sim.pending_key_len
		key_buf := g_ws_sim.pending_key
		if key_len > 0 do g_ws_sim.pending_key_len = 0
		sync.mutex_unlock(&g_ws_sim.mutex)
		if key_len <= 0 do return 0, .None, false
		event, _ := sim_next()
		if event == .Handshake_Garbage {
			return copy(buf, "HTTP/1.1 200 NOPE\r\n\r\n"), .None, true
		}
		if event == .Handshake_Cut do return 0, .Other, true
		sync.mutex_lock(&g_ws_sim.mutex)
		g_ws_sim.tape_pos = max(g_ws_sim.tape_pos - 1, 0)
		sync.mutex_unlock(&g_ws_sim.mutex)
		accept := ws_accept_for_key(string(key_buf[:key_len]))
		response := strings.concatenate(
			{
				"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nSec-WebSocket-Accept: ",
				accept,
				"\r\n\r\n",
			},
			context.temp_allocator,
		)
		return copy(buf, response), .None, true
	}

	@(private = "file")
	sim_store_tail :: proc(tail: []u8) {
		sync.mutex_lock(&g_ws_sim.mutex)
		g_ws_sim.split_tail_len = copy(g_ws_sim.split_tail[:], tail)
		sync.mutex_unlock(&g_ws_sim.mutex)
	}

	@(private = "file")
	sim_recv_data_event :: proc(event: Ws_Sim_Event, buf: []u8) -> (int, Ws_Net_Err, bool) {
		#partial switch event {
		case .Frame_Text, .Frame_Binary:
			payload: [24]u8
			for index in 0 ..< len(payload) do payload[index] = u8('a' + (sim_rand() % 26))
			opcode := u8(WS_OP_TEXT) if event == .Frame_Text else u8(WS_OP_BINARY)
			sync.atomic_add(&g_ws_sim.frames_served, 1)
			return sim_server_frame(buf, opcode, payload[:]), .None, true
		case .Frame_Split:
			frame: [64]u8
			payload: [30]u8
			for index in 0 ..< len(payload) do payload[index] = u8('A' + (sim_rand() % 26))
			total := sim_server_frame(frame[:], WS_OP_TEXT, payload[:])
			half := total / 2
			sim_store_tail(frame[half:total])
			sync.atomic_add(&g_ws_sim.frames_served, 1)
			return copy(buf, frame[:half]), .None, true
		case .Frame_Fragmented:
			part_a, part_b: [12]u8
			for index in 0 ..< len(part_a) do part_a[index] = u8('a' + (sim_rand() % 26))
			for index in 0 ..< len(part_b) do part_b[index] = u8('a' + (sim_rand() % 26))
			tail: [64]u8
			tail_len := sim_server_frame(tail[:], WS_OP_CONTINUATION, part_b[:], fin = true)
			sim_store_tail(tail[:tail_len])
			sync.atomic_add(&g_ws_sim.frames_served, 1)
			return sim_server_frame(buf, WS_OP_TEXT, part_a[:], fin = false), .None, true
		case .Frame_Burst:
			g_ws_sim.burst_remaining = WS_SIM_BURST_FRAMES
			return sim_recv_pending_burst(buf)
		}
		return 0, .None, false
	}

	@(private)
	sim_recv_event :: proc(event: Ws_Sim_Event, buf: []u8) -> (int, Ws_Net_Err) {
		if count, err, handled := sim_recv_data_event(event, buf); handled do return count, err
		#partial switch event {
		case .Frame_Ping:
			return sim_server_frame(buf, WS_OP_PING, {}), .None
		case .Frame_Garbage:
			buf[0] = 0x80
			buf[1] = 0x02
			buf[2] = u8(sim_rand())
			buf[3] = u8(sim_rand())
			return 4, .None
		case .Server_Close:
			return sim_server_frame(buf, WS_OP_CLOSE, {}), .None
		case .Cut:
			return 0, .Other
		case .Timeout:
			return 0, .Timeout
		}
		return 0, .Other
	}

	ws_net_recv :: proc(sock: cnet.TCP_Socket, buf: []u8) -> (int, Ws_Net_Err) {
		if count, err, handled := sim_recv_pending_burst(buf); handled do return count, err
		if count, err, handled := sim_recv_split_tail(buf); handled do return count, err
		if count, err, handled := sim_recv_handshake(buf); handled do return count, err
		event, live := sim_next()
		if !live {
			time.sleep(ws_scaled(WS_RECV_TIMEOUT))
			return 0, .Timeout
		}
		return sim_recv_event(event, buf)
	}

	ws_net_close :: proc(sock: cnet.TCP_Socket) {
	}

	ws_net_set_recv_timeout :: proc(sock: cnet.TCP_Socket, d: time.Duration) {
	}
}

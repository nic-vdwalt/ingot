#+build !js
// LIB-CANDIDATE: this package must import only core:* — never app packages.
// Hand-rolled RFC 6455 WebSocket client (text frames, no TLS). The worker
// thread runs dial + HTTP upgrade handshake + the recv loop; the main thread
// polls a mutex-guarded queue.
package ingotnet

import cnet "core:net"
import "core:strings"
import "core:fmt"
import "core:encoding/base64"
import "core:crypto/legacy/sha1"
import "core:math/rand"
import "core:thread"
import "core:sync"
import "core:time"

// WebSocket connection state.
WS_State :: enum {
	Disconnected,
	Connecting,
	Reconnecting, // recovering an established connection after a drop
	Connected,
	Error,
}

// WebSocket opcode constants.
WS_OP_TEXT   :: 0x1
WS_OP_BINARY :: 0x2
WS_OP_CLOSE  :: 0x8
WS_OP_PING   :: 0x9
WS_OP_PONG   :: 0xA

// Maximum accepted payload per frame. Session-resume history is sent in one
// outbound server frame and can exceed 1 MiB for long chats; match the server's
// inbound ceiling so valid history does not look like a dropped connection.
WS_MAX_PAYLOAD :: 32 * 1024 * 1024

// Bound on undrained received messages (Tiger Style: every queue has a fixed
// upper bound). If the consumer stops draining, the oldest message is dropped
// (counted in recv_dropped) instead of growing memory without limit.
WS_MAX_QUEUED_MESSAGES :: 1024

// Liveness/reconnect tuning. The live socket carries a recv read deadline so a
// half-open TCP drop (Wi-Fi/VPN/sleep — no FIN/RST) is detected instead of
// blocking the worker forever: each timeout window sends a PING (the server
// auto-replies PONG), and the connection is declared dead once no bytes arrive
// for WS_DEAD_AFTER. WS_RECONNECT_WAIT backs off between dial cycles.
WS_RECV_TIMEOUT   :: 5 * time.Second
WS_DEAD_AFTER     :: 15 * time.Second
WS_RECONNECT_WAIT :: 1 * time.Second

// Thread-safe message queue entry for received WebSocket messages.
WS_Message :: struct {
	data:   string,
	binary: bool,
}

// Result of parsing one frame with ws_parse_frame.
WS_Parse_Status :: enum {
	Ok,        // one complete frame parsed; payload is unmasked
	Need_More, // buf does not yet hold a complete frame (consumed == 0)
	Too_Big,   // declared length is negative (64-bit overflow) or > WS_MAX_PAYLOAD
}

// A single parsed RFC 6455 frame. payload slices into the caller's buffer
// (unmasked in place) and is only valid until that buffer is mutated/freed.
WS_Frame :: struct {
	opcode:  u8,
	payload: []u8,
	masked:  bool,
}

// Parse one WebSocket frame from the front of buf. Pure except for in-place
// unmasking of the payload (deterministic — no I/O, no shared state), so it
// is directly fuzzable. Quirks preserved from the original inline parser:
// FIN/RSV bits are ignored and masked server frames are tolerated even
// though RFC 6455 forbids them.
//
// On .Ok, consumed is the full frame size (header [+4 mask] + payload) and
// frame.payload lies within buf[:consumed]. On .Need_More / .Too_Big,
// consumed is 0; .Too_Big is a protocol violation — the caller should drop
// the connection rather than buffer unbounded data.
ws_parse_frame :: proc(buf: []u8) -> (frame: WS_Frame, consumed: int, status: WS_Parse_Status) {
	total := len(buf)
	if total < 2 do return {}, 0, .Need_More

	opcode := buf[0] & 0x0F
	masked := (buf[1] & 0x80) != 0
	payload_len := int(buf[1] & 0x7F)
	header_size := 2

	if payload_len == 126 {
		if total < 4 do return {}, 0, .Need_More
		payload_len = int(buf[2]) << 8 | int(buf[3])
		header_size = 4
	} else if payload_len == 127 {
		if total < 10 do return {}, 0, .Need_More
		payload_len = 0
		for i := 0; i < 8; i += 1 {
			payload_len = payload_len << 8 | int(buf[2 + i])
		}
		header_size = 10
	}

	// payload_len < 0 catches a 64-bit length overflowing signed int.
	if payload_len < 0 || payload_len > WS_MAX_PAYLOAD {
		return {}, 0, .Too_Big
	}

	mask_offset := header_size
	if masked {
		header_size += 4
	}

	total_frame := header_size + payload_len
	if total_frame > total do return {}, 0, .Need_More

	payload := buf[header_size:header_size + payload_len]
	if masked {
		mask_key := buf[mask_offset:mask_offset + 4]
		for i := 0; i < payload_len; i += 1 {
			payload[i] ~= mask_key[i % 4]
		}
	}

	return WS_Frame{opcode = opcode, payload = payload, masked = masked}, total_frame, .Ok
}

// Build a complete client frame (FIN set, mask bit set, payload XOR-masked)
// without touching the socket. The mask key is injected so tests can encode
// deterministically; ws_send_frame supplies a random key. The returned slice
// is owned by the caller.
ws_encode_frame :: proc(opcode: u8, payload: []u8, mask_key: [4]u8, allocator := context.allocator) -> []u8 {
	header_size := 2
	if len(payload) >= 65536 {
		header_size = 10
	} else if len(payload) >= 126 {
		header_size = 4
	}
	frame := make([]u8, header_size + 4 + len(payload), allocator)

	// FIN bit + opcode.
	frame[0] = 0x80 | opcode

	// Payload length with mask bit set (client must mask).
	mask_bit: u8 = 0x80
	if len(payload) < 126 {
		frame[1] = mask_bit | u8(len(payload))
	} else if len(payload) < 65536 {
		frame[1] = mask_bit | 126
		frame[2] = u8(len(payload) >> 8)
		frame[3] = u8(len(payload) & 0xFF)
	} else {
		frame[1] = mask_bit | 127
		for i := 7; i >= 0; i -= 1 {
			frame[2 + (7 - i)] = u8((len(payload) >> uint(i * 8)) & 0xFF)
		}
	}

	// Parameters are not addressable in Odin; copy the key to a local so it
	// can be sliced.
	key := mask_key
	copy(frame[header_size:], key[:])

	// Masked payload: bulk-copy then XOR in place.
	body := header_size + 4
	copy(frame[body:], payload)
	for i := 0; i < len(payload); i += 1 {
		frame[body + i] ~= key[i % 4]
	}
	return frame
}

WebSocket :: struct {
	// Socket lifecycle is shared between the worker thread (dial/assign) and
	// ws_close on the main thread (close). sock_mutex guards socket +
	// socket_open so a close cannot race the worker storing a fresh socket.
	socket:      cnet.TCP_Socket,
	socket_open: bool,
	sock_mutex:  sync.Mutex,

	// Written by the worker thread, read by the main thread — always access
	// with sync.atomic_load / atomic_store (ws_state is the public read).
	state:        WS_State,
	host:         string,
	port:         int,
	max_attempts: int,

	// Self-healing: the worker re-dials on every drop until ws_close, so the
	// thread lives for the whole session. conn_gen is bumped on each successful
	// (re)handshake — consumers poll it (ws_conn_gen) to re-establish app-level
	// subscriptions after a recovery. auto_reconnect=false restores the legacy
	// one-shot behaviour (worker exits after the first drop).
	conn_gen:       int,
	auto_reconnect: bool,

	// Thread-safe receive queue, bounded at WS_MAX_QUEUED_MESSAGES.
	recv_queue:   [dynamic]WS_Message,
	recv_mutex:   sync.Mutex,
	recv_dropped: u64, // messages discarded because recv_queue hit its cap

	// Optional wake hook, called from the worker thread after a message is
	// queued or the state changes, so an event-driven-idle frame loop repaints
	// promptly instead of waiting for its idle-floor tick (gfx.RequestRedraw
	// fits the signature). Set before ws_start_connect; nil means no-op.
	wake: proc "contextless" (),

	// ws_close broadcasts stop_cond so worker backoff waits (dial retry,
	// reconnect) end early instead of sleeping out their full duration.
	stop_mutex: sync.Mutex,
	stop_cond:  sync.Cond,

	// Send serialization (PONG frames go out from the recv thread while text
	// frames are sent from the main thread).
	send_mutex: sync.Mutex,

	// Background thread: runs dial + handshake, then the recv loop. running
	// is written by ws_close and the worker and read across threads — always
	// access it with sync.atomic_load / atomic_store.
	recv_thread: ^thread.Thread,
	running:     bool,
}

// Initialize a WebSocket connection.
ws_init :: proc() -> WebSocket {
	ws: WebSocket
	ws.state = .Disconnected
	ws.recv_queue = make([dynamic]WS_Message)
	ws.running = false
	return ws
}

// Start connecting to the WebSocket server on a background worker thread.
// The worker retries dial up to max_attempts, performs the HTTP upgrade
// handshake, then runs the recv loop on the same thread. The caller polls
// ws.state for .Connected / .Error. Never blocks the calling thread.
//
// Blocking network calls (dial + handshake recv) must not run on the render
// thread: on Windows, connect() to a loopback port that is not listening yet
// takes ~0.5-1s per attempt, which would freeze the UI.
ws_start_connect :: proc(ws: ^WebSocket, host: string, port: int, max_attempts: int) {
	ws.host = host
	ws.port = port
	ws.max_attempts = max_attempts
	ws.auto_reconnect = true
	ws.conn_gen = 0
	sync.atomic_store(&ws.state, WS_State.Connecting)
	sync.atomic_store(&ws.running, true)

	ws.recv_thread = thread.create(proc(t: ^thread.Thread) {
		ws_connect_worker(cast(^WebSocket)t.data)
	})
	if ws.recv_thread == nil {
		sync.atomic_store(&ws.running, false)
		sync.atomic_store(&ws.state, WS_State.Error)
		return
	}
	ws.recv_thread.data = ws
	thread.start(ws.recv_thread)
}

// Resolve a host string (dotted quad or DNS name) + port into an endpoint.
// (Native implementation lives in ws_transport.odin as ws_net_resolve.)

// ws_stop_wait sleeps up to d but wakes early when ws_close clears running,
// so dial-retry and reconnect backoffs never delay shutdown by their full
// length. Timeout expiry is the normal path — nothing signals during routine
// backoff, only ws_close broadcasts.
@(private = "file")
ws_stop_wait :: proc(ws: ^WebSocket, d: time.Duration) {
	assert(d > 0, "backoff wait must be positive")
	sync.mutex_lock(&ws.stop_mutex)
	defer sync.mutex_unlock(&ws.stop_mutex)
	if !sync.atomic_load(&ws.running) do return
	_ = sync.cond_wait_with_timeout(&ws.stop_cond, &ws.stop_mutex, ws_scaled(d))
}

// ws_notify nudges the app's frame loop (if a wake hook is installed) so a
// queued message or state change is rendered promptly even when the app idles
// in event-driven frame mode between inputs.
@(private = "file")
ws_notify :: proc(ws: ^WebSocket) {
	if ws.wake != nil do ws.wake()
}

// ws_set_state publishes a state transition from the worker thread (atomic —
// the main thread reads concurrently) and wakes the frame loop so connection
// status changes appear without waiting for the idle floor.
@(private = "file")
ws_set_state :: proc(ws: ^WebSocket, s: WS_State) {
	sync.atomic_store(&ws.state, s)
	ws_notify(ws)
}

// ws_enqueue appends one received message under recv_mutex, keeping the queue
// bounded: if the main thread stalls and stops draining, the oldest message
// is dropped (and counted) rather than letting memory grow without limit —
// for a UI consumer the latest data wins.
@(private = "file")
ws_enqueue :: proc(ws: ^WebSocket, data: string, binary: bool) {
	sync.mutex_lock(&ws.recv_mutex)
	if len(ws.recv_queue) >= WS_MAX_QUEUED_MESSAGES {
		oldest := ws.recv_queue[0]
		ordered_remove(&ws.recv_queue, 0)
		delete(oldest.data)
		ws.recv_dropped += 1
	}
	append(&ws.recv_queue, WS_Message{data = data, binary = binary})
	assert(len(ws.recv_queue) <= WS_MAX_QUEUED_MESSAGES, "recv queue bound violated")
	sync.mutex_unlock(&ws.recv_mutex)
	ws_notify(ws)
}

// One dial cycle: resolve -> dial -> publish socket -> HTTP upgrade handshake,
// retried up to max_attempts. Returns true with ws.socket live + a recv read
// deadline set (see ws_recv_loop's heartbeat). Returns false if every attempt
// failed or ws_close cut in. The socket is left retracted on failure.
@(private = "file")
ws_dial_and_handshake :: proc(ws: ^WebSocket) -> bool {
	for attempt := 0; attempt < ws.max_attempts && sync.atomic_load(&ws.running); attempt += 1 {
		addr, resolved := ws_net_resolve(ws.host, ws.port)
		if !resolved {
			ws_stop_wait(ws, 200 * time.Millisecond)
			continue
		}
		sock, dialed := ws_net_dial(addr)
		if !dialed {
			ws_stop_wait(ws, 50 * time.Millisecond)
			continue
		}

		// Publish the socket so ws_close can close it to unblock a recv.
		sync.mutex_lock(&ws.sock_mutex)
		if !sync.atomic_load(&ws.running) {
			sync.mutex_unlock(&ws.sock_mutex)
			ws_net_close(sock)
			return false
		}
		ws.socket = sock
		ws.socket_open = true
		sync.mutex_unlock(&ws.sock_mutex)

		if ws_handshake(ws, sock) {
			// Live read deadline: ws_handshake resets the socket to blocking
			// after the 101 response, so re-arm it here for the recv loop.
			ws_net_set_recv_timeout(sock, WS_RECV_TIMEOUT)
			return true
		}

		// Handshake failed: retract the socket and retry.
		sync.mutex_lock(&ws.sock_mutex)
		if ws.socket_open {
			ws_net_close(ws.socket)
			ws.socket_open = false
		}
		sync.mutex_unlock(&ws.sock_mutex)
		ws_stop_wait(ws, 50 * time.Millisecond)
	}
	return false
}

// Worker thread body: a self-healing loop of dial -> handshake -> recv loop.
// The thread lives for the whole session; every drop re-dials (unless
// auto_reconnect is off or ws_close set running=false). conn_gen is bumped on
// each successful handshake so consumers can re-establish subscriptions.
@(private = "file")
ws_connect_worker :: proc(ws: ^WebSocket) {
	first := true
	for sync.atomic_load(&ws.running) {
		ws_set_state(ws, first ? .Connecting : .Reconnecting)

		if !ws_dial_and_handshake(ws) {
			if !ws.auto_reconnect || !sync.atomic_load(&ws.running) {
				break
			}
			ws_stop_wait(ws, WS_RECONNECT_WAIT)
			continue
		}

		first = false
		sync.atomic_add(&ws.conn_gen, 1)
		// Re-check running before publishing Connected: ws_close may have
		// raced the handshake (its socket-publish gate ran before running
		// flipped, but the handshake still completed against a buffered
		// response). Publishing Connected after close would leave a dead
		// socket reporting Connected.
		if !sync.atomic_load(&ws.running) do break
		ws_set_state(ws, .Connected)
		ws_recv_loop(ws) // returns when the socket drops

		// Retract the dropped socket before the next dial cycle.
		sync.mutex_lock(&ws.sock_mutex)
		if ws.socket_open {
			ws_net_close(ws.socket)
			ws.socket_open = false
		}
		sync.mutex_unlock(&ws.sock_mutex)

		if !ws.auto_reconnect || !sync.atomic_load(&ws.running) {
			break
		}
		ws_stop_wait(ws, WS_RECONNECT_WAIT)
	}

	// The worker exiting means no connection is live: normalize the state
	// unconditionally. The pre-fix condition preserved a stale .Connected
	// when ws_close raced the recv loop's running check — the reconnect
	// fuzzer (fuzz/wsreconn) found that interleaving.
	ws_set_state(ws, .Disconnected)
	sync.atomic_store(&ws.running, false)
}

// Send the HTTP upgrade request and validate the 101 response, including the
// Sec-WebSocket-Accept header (base64(sha1(key + RFC 6455 GUID))).
@(private = "file")
ws_handshake :: proc(ws: ^WebSocket, sock: cnet.TCP_Socket) -> bool {
	key := generate_ws_key()
	request := fmt.tprintf(
		"GET /ws HTTP/1.1\r\nHost: %s:%d\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\n\r\n",
		ws.host, ws.port, key,
	)

	request_bytes := transmute([]u8)request
	if _, send_err := ws_net_send(sock, request_bytes); send_err != .None {
		return false
	}

	// Bound the wait for the 101 response so a wedged server cannot park the
	// worker forever; restore blocking mode for the recv loop afterward.
	ws_net_set_recv_timeout(sock, 2 * time.Second)
	buf: [2048]u8
	n, recv_err := ws_net_recv(sock, buf[:])
	ws_net_set_recv_timeout(sock, time.Duration(0))
	if recv_err != .None || n == 0 {
		return false
	}

	response := string(buf[:n])
	if !strings.contains(response, " 101 ") && !strings.has_prefix(response, "HTTP/1.1 101") {
		return false
	}
	return strings.contains(response, ws_accept_for_key(key))
}

// ws_accept_for_key computes the expected Sec-WebSocket-Accept value for a
// handshake key: base64(sha1(key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")).
// Package-private (not file-private) so ws_fuzz_test.odin can fuzz it.
@(private)
ws_accept_for_key :: proc(key: string) -> string {
	combined := fmt.tprintf("%s258EAFA5-E914-47DA-95CA-C5AB0DC85B11", key)
	ctx: sha1.Context
	sha1.init(&ctx)
	sha1.update(&ctx, transmute([]u8)combined)
	digest: [sha1.DIGEST_SIZE]u8
	sha1.final(&ctx, digest[:])
	return base64.encode(digest[:], allocator = context.temp_allocator)
}

// Background receive loop. Returns (without clearing ws.running) when the
// socket drops, so ws_connect_worker can re-dial. A recv read deadline
// (WS_RECV_TIMEOUT, set after the handshake) makes a silent half-open drop
// detectable: each timeout window sends a PING and, if no bytes have arrived
// for WS_DEAD_AFTER, declares the connection dead. Only ws_close clears
// ws.running (which ends the whole session).
@(private = "file")
ws_recv_loop :: proc(ws: ^WebSocket) {
	scratch: [65536]u8
	acc := make([dynamic]u8) // growable accumulator (handles frames > 64 KB)
	defer delete(acc)

	last_activity := time.now()
	for sync.atomic_load(&ws.running) {
		n, err := ws_net_recv(ws.socket, scratch[:])
		if err != .None {
			// A recv timeout is not a disconnect: probe liveness with a PING
			// (the server auto-replies PONG, counted as activity below) and
			// only give up once the connection has been silent too long.
			if err == .Timeout {
				ws_send_frame(ws, WS_OP_PING, nil)
				if time.since(last_activity) > ws_scaled(WS_DEAD_AFTER) {
					ws_set_state(ws, .Disconnected)
					return
				}
				continue
			}
			ws_set_state(ws, .Disconnected)
			return
		}
		if n == 0 {
			// Graceful close (per core:net: 0 bytes + nil err == peer closed).
			ws_set_state(ws, .Disconnected)
			return
		}
		last_activity = time.now() // any bytes (events OR a PONG) = alive
		append(&acc, ..scratch[:n])
		total := len(acc)
		buf := acc[:]

		// Parse WebSocket frame(s) from buffer.
		offset := 0
		for offset < total {
			frame, consumed, status := ws_parse_frame(buf[offset:])
			if status == .Need_More do break
			if status == .Too_Big {
				// Oversized frame: protocol violation — drop the connection
				// rather than buffering unbounded data (worker will re-dial).
				ws_set_state(ws, .Disconnected)
				return
			}

			switch frame.opcode {
			case WS_OP_TEXT:
				ws_enqueue(ws, strings.clone(string(frame.payload)), false)

			case WS_OP_BINARY:
				ws_enqueue(ws, strings.clone(string(frame.payload)), true)

			case 0x0:
				// Continuation frames are unsupported (server never fragments
				// per PROTOCOL.md); treat as a protocol error and re-dial.
				ws_set_state(ws, .Disconnected)
				return

			case WS_OP_PING:
				ws_send_frame(ws, WS_OP_PONG, frame.payload)

			case WS_OP_CLOSE:
				ws_set_state(ws, .Disconnected)
				return
			}

			offset += consumed
		}

		// Drop consumed bytes; keep any partial-frame tail for the next recv.
		if offset > 0 {
			remove_range(&acc, 0, offset)
		}
	}
}

// Send a text message over WebSocket.
ws_send :: proc(ws: ^WebSocket, data: string) -> bool {
	if ws_state(ws) != .Connected do return false
	return ws_send_frame(ws, WS_OP_TEXT, transmute([]u8)data)
}

// Send a binary message over WebSocket.
ws_send_binary :: proc(ws: ^WebSocket, data: []u8) -> bool {
	if ws_state(ws) != .Connected do return false
	if len(data) > WS_MAX_PAYLOAD do return false
	return ws_send_frame(ws, WS_OP_BINARY, data)
}

// Send a raw WebSocket frame.
ws_send_frame :: proc(ws: ^WebSocket, opcode: u8, payload: []u8) -> bool {
	assert(opcode <= 0x0F, "opcode is a 4-bit field")
	assert(len(payload) <= WS_MAX_PAYLOAD, "payload exceeds WS_MAX_PAYLOAD")

	// Masking key (4 random bytes).
	mask_key: [4]u8
	for i in 0..<4 {
		mask_key[i] = u8(rand.uint32() & 0xFF)
	}
	frame := ws_encode_frame(opcode, payload, mask_key)
	defer delete(frame)

	// Serialize writes across threads (PONGs from the worker vs. text from
	// the main thread), then snapshot the socket under sock_mutex so a send
	// cannot use a handle that ws_close or a reconnect already retired.
	sync.mutex_lock(&ws.send_mutex)
	defer sync.mutex_unlock(&ws.send_mutex)

	sync.mutex_lock(&ws.sock_mutex)
	if !ws.socket_open {
		sync.mutex_unlock(&ws.sock_mutex)
		return false
	}
	sock := ws.socket
	sync.mutex_unlock(&ws.sock_mutex)

	// A single net.send may write only part of the frame; loop until the
	// whole frame is sent so the server never sees a truncated frame.
	total := 0
	for total < len(frame) {
		n, err := ws_net_send(sock, frame[total:])
		if err != .None do return false
		if n <= 0 do return false
		total += n
	}
	return true
}

// Drain all received messages in one lock (call from main thread). The
// returned slice is temp-allocated; each message's `data` string is heap-
// allocated and owned by the caller (delete after processing).
ws_drain :: proc(ws: ^WebSocket) -> []WS_Message {
	sync.mutex_lock(&ws.recv_mutex)
	defer sync.mutex_unlock(&ws.recv_mutex)

	if len(ws.recv_queue) == 0 do return nil

	result := make([]WS_Message, len(ws.recv_queue), context.temp_allocator)
	for msg, i in ws.recv_queue {
		result[i] = msg
	}
	clear(&ws.recv_queue)
	return result
}

// Thread-safe check for undrained received messages.
ws_has_pending :: proc(ws: ^WebSocket) -> bool {
	sync.mutex_lock(&ws.recv_mutex)
	defer sync.mutex_unlock(&ws.recv_mutex)
	return len(ws.recv_queue) > 0
}

// ws_conn_gen returns a counter incremented on each successful (re)handshake.
// Consumers poll it to re-establish app-level subscriptions after a recovery:
// when the value advances, a fresh connection is live and any prior server-side
// subscription (bound to the old socket) is gone.
ws_conn_gen :: proc(ws: ^WebSocket) -> int {
	return sync.atomic_load(&ws.conn_gen)
}

// ws_state returns the connection state with an atomic read — the worker
// thread writes it concurrently, so a plain field read would be racy.
ws_state :: proc(ws: ^WebSocket) -> WS_State {
	return sync.atomic_load(&ws.state)
}

// Close the WebSocket connection. Stops the worker thread: broadcasting
// stop_cond ends any backoff wait early, closing the socket unblocks a
// blocking recv (handshake or recv loop), and a dial in flight fails on its
// own — the worker then exits on running == false.
ws_close :: proc(ws: ^WebSocket) {
	sync.atomic_store(&ws.running, false)

	// Wake a worker parked in ws_stop_wait so shutdown is prompt (broadcast
	// under the mutex — never lost against a concurrent wait).
	sync.mutex_lock(&ws.stop_mutex)
	sync.cond_broadcast(&ws.stop_cond)
	sync.mutex_unlock(&ws.stop_mutex)

	// Best-effort CLOSE frame while the socket is still open. Must run before
	// the close below and outside sock_mutex — ws_send_frame takes sock_mutex
	// itself to snapshot the socket.
	if sync.atomic_load(&ws.state) == .Connected {
		ws_send_frame(ws, WS_OP_CLOSE, nil)
	}

	sync.mutex_lock(&ws.sock_mutex)
	if ws.socket_open {
		ws_net_close(ws.socket)
		ws.socket_open = false
	}
	sync.mutex_unlock(&ws.sock_mutex)
	sync.atomic_store(&ws.state, WS_State.Disconnected)

	if ws.recv_thread != nil {
		thread.join(ws.recv_thread)
		thread.destroy(ws.recv_thread)
		ws.recv_thread = nil
	}

	// Clean up queue (idempotent — ws_close may be called more than once).
	for msg in ws.recv_queue {
		delete(msg.data)
	}
	delete(ws.recv_queue)
	ws.recv_queue = nil
}

// Generate a random WebSocket key for the handshake.
@(private = "file")
generate_ws_key :: proc() -> string {
	key_bytes: [16]u8
	for i in 0..<16 {
		key_bytes[i] = u8(rand.uint32() & 0xFF)
	}
	return base64.encode(key_bytes[:], allocator = context.temp_allocator)
}
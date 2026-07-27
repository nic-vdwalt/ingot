#+build !js
// LIB-CANDIDATE: this package must import only core:* and ingot:threadhook —
// never app packages. threadhook is the one permitted exception: it is a
// dependency-free leaf (base:runtime + core:sync) that exists so worker-thread
// assertions can reach the embedder's crash reporter, which they otherwise
// cannot because core:thread hands every worker a fresh
// runtime.default_context().
// Bounded RFC 6455 WebSocket client over plaintext TCP or verified TLS. The
// worker thread runs dial + HTTP upgrade handshake + the recv loop; the main
// thread polls a mutex-guarded queue.
package ingotnet

import "core:crypto"
import "core:crypto/legacy/sha1"
import "core:encoding/base64"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import "ingot:threadhook"

// WebSocket connection state.
WS_State :: enum {
	Disconnected,
	Connecting,
	Reconnecting, // recovering an established connection after a drop
	Connected,
	Error,
}

// WebSocket opcode constants.
WS_OP_CONTINUATION :: 0x0
WS_OP_TEXT :: 0x1
WS_OP_BINARY :: 0x2
WS_OP_CLOSE :: 0x8
WS_OP_PING :: 0x9
WS_OP_PONG :: 0xA

// Maximum accepted payload per frame. Session-resume history is sent in one
// outbound server frame and can exceed 1 MiB for long chats; match the server's
// inbound ceiling so valid history does not look like a dropped connection.
WS_MAX_PAYLOAD :: 32 * 1024 * 1024

// Bound on undrained received messages (Tiger Style: every queue has a fixed
// upper bound). If the consumer stops draining, the oldest message is dropped
// (counted in recv_dropped) instead of growing memory without limit.
WS_MAX_QUEUED_MESSAGES :: 1024
WS_MAX_QUEUED_BYTES :: 64 * 1024 * 1024

// Liveness/reconnect tuning. The live socket carries a recv read deadline so a
// half-open TCP drop (Wi-Fi/VPN/sleep — no FIN/RST) is detected instead of
// blocking the worker forever: each timeout window sends a PING (the server
// auto-replies PONG), and the connection is declared dead once no bytes arrive
// for WS_DEAD_AFTER. WS_RECONNECT_WAIT backs off between dial cycles.
WS_RECV_TIMEOUT :: 100 * time.Millisecond
WS_DEAD_AFTER :: 15 * time.Second
WS_RECONNECT_WAIT :: 1 * time.Second
WS_CONNECT_TIMEOUT :: 10 * time.Second
WS_HANDSHAKE_TIMEOUT :: 5 * time.Second

WS_Options :: struct {
	max_attempts:      int,
	connect_timeout:   time.Duration,
	handshake_timeout: time.Duration,
	ca_file:           string,
}

WS_Error :: enum u8 {
	None,
	Invalid_URL,
	Resolve,
	Connect,
	TLS,
	Handshake,
	Cancelled,
}

// Thread-safe message queue entry for received WebSocket messages.
WS_Message :: struct {
	data:   string,
	binary: bool,
}

// Result of parsing one frame with ws_parse_frame.
WS_Parse_Status :: enum {
	Ok, // one complete frame parsed; payload is unmasked
	Need_More, // buf does not yet hold a complete frame (consumed == 0)
	Too_Big, // declared length is negative (64-bit overflow) or > WS_MAX_PAYLOAD
}

// A single parsed RFC 6455 frame. payload slices into the caller's buffer
// (unmasked in place) and is only valid until that buffer is mutated/freed.
WS_Frame :: struct {
	opcode:  u8,
	payload: []u8,
	masked:  bool,
	fin:     bool,
}

// Parse one server WebSocket frame from the front of buf. The parser rejects
// extension bits, client-direction masking, reserved opcodes, noncanonical
// lengths, and invalid control frames before exposing payload bytes.
//
// On .Ok, consumed is the full frame size (header [+4 mask] + payload) and
// frame.payload lies within buf[:consumed]. On .Need_More / .Too_Big,
// consumed is 0; .Too_Big is a protocol violation — the caller should drop
// the connection rather than buffer unbounded data.
ws_parse_frame :: proc(buf: []u8) -> (frame: WS_Frame, consumed: int, status: WS_Parse_Status) {
	assert(len(buf) >= 0)
	total := len(buf)
	if total < 2 do return {}, 0, .Need_More

	opcode := buf[0] & 0x0F
	fin := (buf[0] & 0x80) != 0
	masked := (buf[1] & 0x80) != 0
	if (buf[0] & 0x70) != 0 || masked do return {}, 0, .Too_Big
	if opcode != WS_OP_CONTINUATION &&
	   opcode != WS_OP_TEXT &&
	   opcode != WS_OP_BINARY &&
	   opcode != WS_OP_CLOSE &&
	   opcode != WS_OP_PING &&
	   opcode != WS_OP_PONG {
		return {}, 0, .Too_Big
	}
	payload_len := int(buf[1] & 0x7F)
	header_size := 2

	if payload_len == 126 {
		if total < 4 do return {}, 0, .Need_More
		payload_len = int(buf[2]) << 8 | int(buf[3])
		if payload_len < 126 do return {}, 0, .Too_Big
		header_size = 4
	} else if payload_len == 127 {
		if total < 10 do return {}, 0, .Need_More
		if (buf[2] & 0x80) != 0 do return {}, 0, .Too_Big
		payload_len = 0
		for i := 0; i < 8; i += 1 {
			payload_len = payload_len << 8 | int(buf[2 + i])
		}
		if payload_len < 65536 do return {}, 0, .Too_Big
		header_size = 10
	}

	// payload_len < 0 catches a 64-bit length overflowing signed int.
	if payload_len < 0 || payload_len > WS_MAX_PAYLOAD {
		return {}, 0, .Too_Big
	}
	if payload_len > max(int) - header_size do return {}, 0, .Too_Big
	if opcode >= WS_OP_CLOSE && (!fin || payload_len > 125) do return {}, 0, .Too_Big

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

	frame = WS_Frame {
		opcode  = opcode,
		payload = payload,
		masked  = masked,
		fin     = fin,
	}
	assert(len(frame.payload) == payload_len, "payload slice must match declared length")
	assert(total_frame >= 2, "a complete frame is at least a 2-byte header")
	return frame, total_frame, .Ok
}

// Reassembly state for fragmented messages (RFC 6455 §5.4). Owned by
// ws_recv_loop (loop-local — the loop owns the connection lifetime).
// Package-private (not file-private) so ws_test.odin can drive reassembly.
@(private)
WS_Frag_State :: struct {
	buf:    [dynamic]u8,
	opcode: u8, // opcode of the initial TEXT/BINARY frame
	active: bool,
}

// ws_handle_data_frame applies one TEXT/BINARY/CONTINUATION frame to the
// reassembly state, enqueueing a complete logical message once FIN closes
// it. Returns false on a protocol violation — a bare continuation, a data
// frame interleaved inside an unfinished fragment sequence, or an assembled
// message exceeding WS_MAX_PAYLOAD — in which case the caller must drop the
// connection (RFC 6455 §5.4 fail-fast).
@(private)
ws_handle_data_frame :: proc(ws: ^WebSocket, frag: ^WS_Frag_State, frame: WS_Frame) -> bool {
	assert(
		frame.opcode == WS_OP_TEXT ||
		frame.opcode == WS_OP_BINARY ||
		frame.opcode == WS_OP_CONTINUATION,
		"data frames only",
	)
	assert(len(frame.payload) <= WS_MAX_PAYLOAD, "parser bounds each frame's payload")

	if frame.opcode == WS_OP_CONTINUATION {
		// A continuation with no fragment in flight is a protocol error.
		if !frag.active do return false
		// The assembled message obeys the same ceiling as a single frame so
		// fragmentation cannot smuggle unbounded data past WS_MAX_PAYLOAD.
		if len(frame.payload) > WS_MAX_PAYLOAD - len(frag.buf) do return false
		append(&frag.buf, ..frame.payload)
		if frame.fin {
			ws_enqueue(ws, strings.clone(string(frag.buf[:])), frag.opcode == WS_OP_BINARY)
			clear(&frag.buf)
			frag.active = false
		}
		return true
	}

	// TEXT/BINARY: starting a new data message inside an unfinished fragment
	// sequence violates RFC 6455 §5.4 (only control frames may interleave).
	if frag.active do return false
	if frame.fin {
		ws_enqueue(ws, strings.clone(string(frame.payload)), frame.opcode == WS_OP_BINARY)
		return true
	}
	frag.active = true
	frag.opcode = frame.opcode
	clear(&frag.buf)
	append(&frag.buf, ..frame.payload)
	return true
}

// Build a complete client frame (FIN set, mask bit set, payload XOR-masked)
// without touching the socket. The mask key is injected so tests can encode
// deterministically; ws_send_frame supplies a random key. The returned slice
// is owned by the caller.
ws_encode_frame :: proc(
	opcode: u8,
	payload: []u8,
	mask_key: [4]u8,
	allocator := context.allocator,
) -> []u8 {
	assert(opcode <= 0x0F)
	assert(len(payload) <= WS_MAX_PAYLOAD)
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
	assert(len(frame) == header_size + 4 + len(payload))
	return frame
}

WebSocket :: struct {
	// Transport lifecycle is shared between the worker and ws_close. TLS handles
	// remain worker-owned; ws_close signals cancellation and joins the worker.
	transport:         Ws_Transport,
	socket_open:       bool,
	sock_mutex:        sync.Mutex,

	// Written by the worker thread, read by the main thread — always access
	// with sync.atomic_load / atomic_store (ws_state is the public read).
	state:             WS_State,
	last_error:        WS_Error,
	host:              string,
	port:              int,
	path:              string,
	secure:            bool,
	ca_file:           string,
	url_storage:       string,
	connect_timeout:   time.Duration,
	handshake_timeout: time.Duration,
	max_attempts:      int,

	// Self-healing: the worker re-dials on every drop until ws_close, so the
	// thread lives for the whole session. conn_gen is bumped on each successful
	// (re)handshake — consumers poll it (ws_conn_gen) to re-establish app-level
	// subscriptions after a recovery. auto_reconnect=false restores the legacy
	// one-shot behaviour (worker exits after the first drop).
	conn_gen:          int,
	auto_reconnect:    bool,

	// Thread-safe receive queue, bounded by message count and aggregate bytes.
	recv_queue:        [dynamic]WS_Message,
	recv_queue_bytes:  u64,
	recv_mutex:        sync.Mutex,
	recv_dropped:      u64, // messages discarded because recv_queue hit its cap

	// Optional wake hook, called from the worker thread after a message is
	// queued or the state changes, so an event-driven-idle frame loop repaints
	// promptly instead of waiting for its idle-floor tick (gfx.RequestRedraw
	// fits the signature). Set before ws_start_connect; nil means no-op.
	wake:              proc "contextless" (),

	// ws_close broadcasts stop_cond so worker backoff waits (dial retry,
	// reconnect) end early instead of sleeping out their full duration.
	stop_mutex:        sync.Mutex,
	stop_cond:         sync.Cond,

	// Send serialization (PONG frames go out from the recv thread while text
	// frames are sent from the main thread).
	send_mutex:        sync.Mutex,

	// Background thread: runs dial + handshake, then the recv loop. running
	// is written by ws_close and the worker and read across threads — always
	// access it with sync.atomic_load / atomic_store.
	recv_thread:       ^thread.Thread,
	running:           bool,
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
	url := fmt.tprintf("ws://%s:%d/ws", host, port)
	_ = ws_start_connect_url(ws, url, WS_Options{max_attempts = max_attempts})
}

ws_start_connect_url :: proc(ws: ^WebSocket, raw_url: string, options: WS_Options = {}) -> bool {
	parsed, parse_err := ws_url_parse(raw_url)
	if parse_err != .None {
		sync.atomic_store(&ws.last_error, WS_Error.Invalid_URL)
		sync.atomic_store(&ws.state, WS_State.Error)
		return false
	}
	if len(ws.url_storage) > 0 do delete(ws.url_storage)
	ws.url_storage = strings.clone(raw_url)
	parsed, parse_err = ws_url_parse(ws.url_storage)
	assert(parse_err == .None, "cloned WebSocket URL failed to parse")
	ws.host = parsed.host
	ws.port = int(parsed.port)
	ws.path = parsed.path
	ws.secure = parsed.scheme == .Wss
	ws.ca_file = options.ca_file
	ws.connect_timeout = options.connect_timeout
	if ws.connect_timeout <= 0 do ws.connect_timeout = WS_CONNECT_TIMEOUT
	ws.handshake_timeout = options.handshake_timeout
	if ws.handshake_timeout <= 0 do ws.handshake_timeout = WS_HANDSHAKE_TIMEOUT
	ws.max_attempts = max(options.max_attempts, 1)
	ws.auto_reconnect = true
	ws.conn_gen = 0
	sync.atomic_store(&ws.last_error, WS_Error.None)
	sync.atomic_store(&ws.state, WS_State.Connecting)
	sync.atomic_store(&ws.running, true)
	ws.recv_thread = thread.create(proc(t: ^thread.Thread) {
		context.assertion_failure_proc = threadhook.install(context.assertion_failure_proc)
		ws_connect_worker(cast(^WebSocket)t.data)
	})
	if ws.recv_thread == nil {
		sync.atomic_store(&ws.running, false)
		sync.atomic_store(&ws.last_error, WS_Error.Connect)
		sync.atomic_store(&ws.state, WS_State.Error)
		return false
	}
	ws.recv_thread.data = ws
	thread.start(ws.recv_thread)
	return true
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
	assert(ws != nil)
	assert(s >= .Disconnected && s <= .Error)
	sync.atomic_store(&ws.state, s)
	ws_notify(ws)
}

// ws_enqueue appends one received message under recv_mutex, keeping the queue
// bounded: if the main thread stalls and stops draining, the oldest message
// is dropped (and counted) rather than letting memory grow without limit —
// for a UI consumer the latest data wins.
@(private = "file")
ws_enqueue :: proc(ws: ^WebSocket, data: string, binary: bool) {
	assert(ws != nil)
	if len(data) > WS_MAX_QUEUED_BYTES {
		delete(data)
		return
	}
	data_bytes := u64(len(data))
	sync.mutex_lock(&ws.recv_mutex)
	for _ in 0 ..< WS_MAX_QUEUED_MESSAGES {
		if len(ws.recv_queue) == 0 ||
		   (len(ws.recv_queue) < WS_MAX_QUEUED_MESSAGES &&
				   ws.recv_queue_bytes <= WS_MAX_QUEUED_BYTES - data_bytes) {
			break
		}
		oldest := ws.recv_queue[0]
		ordered_remove(&ws.recv_queue, 0)
		ws.recv_queue_bytes -= u64(len(oldest.data))
		delete(oldest.data)
		ws.recv_dropped += 1
	}
	assert(len(ws.recv_queue) < WS_MAX_QUEUED_MESSAGES, "recv queue did not make room")
	assert(ws.recv_queue_bytes <= WS_MAX_QUEUED_BYTES - data_bytes, "recv bytes did not make room")
	append(&ws.recv_queue, WS_Message{data = data, binary = binary})
	ws.recv_queue_bytes += data_bytes
	assert(len(ws.recv_queue) <= WS_MAX_QUEUED_MESSAGES, "recv queue bound violated")
	assert(ws.recv_queue_bytes <= WS_MAX_QUEUED_BYTES, "recv queue byte bound violated")
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
		transport: Ws_Transport
		net_err: Ws_Net_Err
		if ws.secure {
			transport, net_err = ws_net_dial_tls(
				ws.host,
				u16(ws.port),
				ws.ca_file,
				ws.connect_timeout,
			)
		} else {
			address, resolved := ws_net_resolve(ws.host, ws.port)
			if !resolved {
				sync.atomic_store(&ws.last_error, WS_Error.Resolve)
				ws_stop_wait(ws, 200 * time.Millisecond)
				continue
			}
			transport, net_err = ws_net_dial(address)
		}
		if net_err != .None {
			error_value := WS_Error.TLS if net_err == .TLS else WS_Error.Connect
			sync.atomic_store(&ws.last_error, error_value)
			if net_err == .TLS do return false
			ws_stop_wait(ws, 50 * time.Millisecond)
			continue
		}
		sync.mutex_lock(&ws.sock_mutex)
		if !sync.atomic_load(&ws.running) {
			sync.mutex_unlock(&ws.sock_mutex)
			ws_net_close(&transport)
			return false
		}
		ws.transport = transport
		ws.socket_open = true
		sync.mutex_unlock(&ws.sock_mutex)
		if ws_handshake(ws, &ws.transport) {
			ws_net_set_recv_timeout(&ws.transport, WS_RECV_TIMEOUT)
			sync.atomic_store(&ws.last_error, WS_Error.None)
			return true
		}
		sync.atomic_store(&ws.last_error, WS_Error.Handshake)
		sync.mutex_lock(&ws.sock_mutex)
		if ws.socket_open {
			ws_net_close(&ws.transport)
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
	assert(ws != nil)
	previous_generation := sync.atomic_load(&ws.conn_gen)
	assert(previous_generation >= 0)
	first := true
	for sync.atomic_load(&ws.running) {
		ws_set_state(ws, first ? .Connecting : .Reconnecting)

		if !ws_dial_and_handshake(ws) {
			failure := sync.atomic_load(&ws.last_error)
			if failure == .TLS || failure == .Handshake {
				ws_set_state(ws, .Error)
				break
			}
			if !ws.auto_reconnect || !sync.atomic_load(&ws.running) do break
			ws_stop_wait(ws, WS_RECONNECT_WAIT)
			continue
		}

		first = false
		sync.atomic_add(&ws.conn_gen, 1)
		generation := sync.atomic_load(&ws.conn_gen)
		assert(generation > previous_generation)
		previous_generation = generation
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
			ws_net_close(&ws.transport)
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
	if ws_state(ws) != .Error do ws_set_state(ws, .Disconnected)
	sync.atomic_store(&ws.running, false)
}

// Send the HTTP upgrade request and validate the 101 response, including the
// Sec-WebSocket-Accept header (base64(sha1(key + RFC 6455 GUID))).
@(private = "file")
ws_handshake :: proc(ws: ^WebSocket, transport: ^Ws_Transport) -> bool {
	key := generate_ws_key()
	if len(key) == 0 do return false
	default_port := (ws.secure && ws.port == 443) || (!ws.secure && ws.port == 80)
	host_value := ws.host
	if !default_port do host_value = fmt.tprintf("%s:%d", ws.host, ws.port)
	request := fmt.tprintf(
		"GET %s HTTP/1.1\r\nHost: %s\r\nUpgrade: websocket\r\n" +
		"Connection: Upgrade\r\nSec-WebSocket-Key: %s\r\n" +
		"Sec-WebSocket-Version: 13\r\n\r\n",
		ws.path,
		host_value,
		key,
	)
	request_bytes := transmute([]u8)request
	total := 0
	for total < len(request_bytes) {
		count, send_err := ws_net_send(transport, request_bytes[total:])
		if send_err != .None || count <= 0 do return false
		total += count
	}
	ws_net_set_recv_timeout(transport, ws.handshake_timeout)
	buf: [2048]u8
	count := 0
	started := time.now()
	for count < len(buf) && time.since(started) < ws.handshake_timeout {
		read, recv_err := ws_net_recv(transport, buf[count:])
		if recv_err == .Timeout {
			time.sleep(10 * time.Millisecond)
			continue
		}
		if recv_err != .None || read == 0 do return false
		count += read
		if strings.contains(string(buf[:count]), "\r\n\r\n") do break
	}
	ws_net_set_recv_timeout(transport, time.Duration(0))
	response := string(buf[:count])
	if !strings.has_prefix(response, "HTTP/1.1 101") do return false
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

	// Fragment reassembly (RFC 6455 §5.4); loop-local so a reconnect always
	// starts with a clean slate.
	frag: WS_Frag_State
	defer delete(frag.buf)

	last_activity := time.now()
	for sync.atomic_load(&ws.running) {
		n, err := ws_net_recv(&ws.transport, scratch[:])
		if err != .None {
			if err == .Timeout && ws.secure {
				time.sleep(10 * time.Millisecond)
				continue
			}
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

			// Control frames must not be fragmented (RFC 6455 §5.5).
			if frame.opcode >= WS_OP_CLOSE && !frame.fin {
				ws_set_state(ws, .Disconnected)
				return
			}

			switch frame.opcode {
			case WS_OP_TEXT, WS_OP_BINARY, WS_OP_CONTINUATION:
				if !ws_handle_data_frame(ws, &frag, frame) {
					ws_set_state(ws, .Disconnected)
					return
				}

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
	assert(ws != nil)
	if ws_state(ws) != .Connected do return false
	if len(data) > WS_MAX_PAYLOAD do return false
	return ws_send_frame(ws, WS_OP_TEXT, transmute([]u8)data)
}

// Send a binary message over WebSocket.
ws_send_binary :: proc(ws: ^WebSocket, data: []u8) -> bool {
	assert(ws != nil)
	if ws_state(ws) != .Connected do return false
	if len(data) > WS_MAX_PAYLOAD do return false
	return ws_send_frame(ws, WS_OP_BINARY, data)
}

// Send a raw WebSocket frame.
ws_send_frame :: proc(ws: ^WebSocket, opcode: u8, payload: []u8) -> bool {
	assert(opcode <= 0x0F, "opcode is a 4-bit field")
	assert(len(payload) <= WS_MAX_PAYLOAD, "payload exceeds WS_MAX_PAYLOAD")

	// Masking keys must be unpredictable for intermediaries to remain safe.
	mask_key: [4]u8
	if !crypto.HAS_RAND_BYTES do return false
	crypto.rand_bytes(mask_key[:])
	frame := ws_encode_frame(opcode, payload, mask_key)
	defer delete(frame)

	// Serialize writes across threads (PONGs from the worker vs. text from
	// the main thread), then keep sock_mutex through the complete write so
	// ws_close or reconnect cannot retire the handle between partial sends.
	sync.mutex_lock(&ws.send_mutex)
	defer sync.mutex_unlock(&ws.send_mutex)

	sync.mutex_lock(&ws.sock_mutex)
	defer sync.mutex_unlock(&ws.sock_mutex)
	if !ws.socket_open do return false

	// A single net.send may write only part of the frame; loop until the
	// whole frame is sent so the server never sees a truncated frame.
	total := 0
	for total < len(frame) {
		n, err := ws_net_send(&ws.transport, frame[total:])
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
	assert(ws != nil)
	sync.mutex_lock(&ws.recv_mutex)
	defer sync.mutex_unlock(&ws.recv_mutex)

	if len(ws.recv_queue) == 0 do return nil

	result := make([]WS_Message, len(ws.recv_queue), context.temp_allocator)
	for msg, i in ws.recv_queue {
		result[i] = msg
	}
	clear(&ws.recv_queue)
	ws.recv_queue_bytes = 0
	assert(len(result) <= WS_MAX_QUEUED_MESSAGES)
	assert(len(ws.recv_queue) == 0)
	assert(ws.recv_queue_bytes == 0)
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

ws_error :: proc(ws: ^WebSocket) -> WS_Error {
	return sync.atomic_load(&ws.last_error)
}

// Close the WebSocket connection. Stops the worker thread: broadcasting
// stop_cond ends any backoff wait early, closing the socket unblocks a
// blocking recv (handshake or recv loop), and a dial in flight fails on its
// own — the worker then exits on running == false.
ws_close :: proc(ws: ^WebSocket) {
	assert(ws != nil)
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
	if ws.socket_open && ws.transport.kind == .TCP {
		ws_net_close(&ws.transport)
		ws.socket_open = false
	}
	sync.mutex_unlock(&ws.sock_mutex)
	sync.atomic_store(&ws.state, WS_State.Disconnected)

	if ws.recv_thread != nil {
		thread.join(ws.recv_thread)
		thread.destroy(ws.recv_thread)
		ws.recv_thread = nil
	}
	sync.atomic_store(&ws.state, WS_State.Disconnected)

	// Clean up queue (idempotent — ws_close may be called more than once).
	for msg in ws.recv_queue {
		delete(msg.data)
	}
	delete(ws.recv_queue)
	ws.recv_queue = nil
	if len(ws.url_storage) > 0 {
		delete(ws.url_storage)
		ws.url_storage = ""
	}
	assert(ws.recv_thread == nil)
	assert(len(ws.recv_queue) == 0)
	assert(sync.atomic_load(&ws.state) == .Disconnected)
}

// Generate a random WebSocket key for the handshake.
@(private = "file")
generate_ws_key :: proc() -> string {
	if !crypto.HAS_RAND_BYTES do return ""
	key_bytes: [16]u8
	crypto.rand_bytes(key_bytes[:])
	return base64.encode(key_bytes[:], allocator = context.temp_allocator)
}

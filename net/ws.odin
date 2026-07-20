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
	Connected,
	Error,
}

// WebSocket opcode constants.
WS_OP_TEXT   :: 0x1
WS_OP_BINARY :: 0x2
WS_OP_CLOSE  :: 0x8
WS_OP_PING   :: 0x9
WS_OP_PONG   :: 0xA

// Maximum accepted payload per frame (matches the server's 1 MiB cap).
WS_MAX_PAYLOAD :: 1 << 20

// Thread-safe message queue entry for received WebSocket messages.
WS_Message :: struct {
	data:   string,
	binary: bool,
}

WebSocket :: struct {
	// Socket lifecycle is shared between the worker thread (dial/assign) and
	// ws_close on the main thread (close). sock_mutex guards socket +
	// socket_open so a close cannot race the worker storing a fresh socket.
	socket:      cnet.TCP_Socket,
	socket_open: bool,
	sock_mutex:  sync.Mutex,

	state:        WS_State,
	host:         string,
	port:         int,
	max_attempts: int,

	// Thread-safe receive queue.
	recv_queue: [dynamic]WS_Message,
	recv_mutex: sync.Mutex,

	// Send serialization (PONG frames go out from the recv thread while text
	// frames are sent from the main thread).
	send_mutex: sync.Mutex,

	// Background thread: runs dial + handshake, then the recv loop.
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
	ws.state = .Connecting
	ws.running = true

	ws.recv_thread = thread.create(proc(t: ^thread.Thread) {
		ws_connect_worker(cast(^WebSocket)t.data)
	})
	if ws.recv_thread == nil {
		ws.running = false
		ws.state = .Error
		return
	}
	ws.recv_thread.data = ws
	thread.start(ws.recv_thread)
}

// Resolve a host string (dotted quad or DNS name) + port into an endpoint.
@(private = "file")
resolve_host :: proc(host: string, port: int) -> (cnet.Endpoint, bool) {
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

// Worker thread body: dial -> handshake -> recv loop.
@(private = "file")
ws_connect_worker :: proc(ws: ^WebSocket) {
	for attempt := 0; attempt < ws.max_attempts && ws.running; attempt += 1 {
		addr, resolved := resolve_host(ws.host, ws.port)
		if !resolved {
			time.sleep(200 * time.Millisecond)
			continue
		}
		sock, err := cnet.dial_tcp(addr)
		if err != nil {
			time.sleep(50 * time.Millisecond)
			continue
		}

		// Publish the socket so ws_close can close it to unblock a recv.
		sync.mutex_lock(&ws.sock_mutex)
		if !ws.running {
			sync.mutex_unlock(&ws.sock_mutex)
			cnet.close(sock)
			break
		}
		ws.socket = sock
		ws.socket_open = true
		sync.mutex_unlock(&ws.sock_mutex)

		if ws_handshake(ws, sock) {
			ws.state = .Connected
			ws_recv_loop(ws)
			return
		}

		// Handshake failed: retract the socket and retry.
		sync.mutex_lock(&ws.sock_mutex)
		if ws.socket_open {
			cnet.close(ws.socket)
			ws.socket_open = false
		}
		sync.mutex_unlock(&ws.sock_mutex)
		time.sleep(50 * time.Millisecond)
	}

	if ws.state != .Connected {
		ws.state = .Error
	}
	ws.running = false
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
	if _, send_err := cnet.send(sock, request_bytes); send_err != nil {
		return false
	}

	// Bound the wait for the 101 response so a wedged server cannot park the
	// worker forever; restore blocking mode for the recv loop afterward.
	_ = cnet.set_option(sock, .Receive_Timeout, 2 * time.Second)
	buf: [2048]u8
	n, recv_err := cnet.recv(sock, buf[:])
	_ = cnet.set_option(sock, .Receive_Timeout, time.Duration(0))
	if recv_err != nil || n == 0 {
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
@(private = "file")
ws_accept_for_key :: proc(key: string) -> string {
	combined := fmt.tprintf("%s258EAFA5-E914-47DA-95CA-C5AB0DC85B11", key)
	ctx: sha1.Context
	sha1.init(&ctx)
	sha1.update(&ctx, transmute([]u8)combined)
	digest: [sha1.DIGEST_SIZE]u8
	sha1.final(&ctx, digest[:])
	return base64.encode(digest[:], allocator = context.temp_allocator)
}

// Background receive loop.
@(private = "file")
ws_recv_loop :: proc(ws: ^WebSocket) {
	scratch: [65536]u8
	acc := make([dynamic]u8) // growable accumulator (handles frames > 64 KB)
	defer delete(acc)

	for ws.running {
		n, err := cnet.recv(ws.socket, scratch[:])
		if err != nil || n == 0 {
			ws.state = .Disconnected
			ws.running = false
			return
		}
		append(&acc, ..scratch[:n])
		total := len(acc)
		buf := acc[:]

		// Parse WebSocket frame(s) from buffer.
		offset := 0
		for offset < total {
			if total - offset < 2 do break

			opcode := buf[offset] & 0x0F
			masked := (buf[offset + 1] & 0x80) != 0
			payload_len := int(buf[offset + 1] & 0x7F)
			header_size := 2

			if payload_len == 126 {
				if total - offset < 4 do break
				payload_len = int(buf[offset + 2]) << 8 | int(buf[offset + 3])
				header_size = 4
			} else if payload_len == 127 {
				if total - offset < 10 do break
				payload_len = 0
				for i := 0; i < 8; i += 1 {
					payload_len = payload_len << 8 | int(buf[offset + 2 + i])
				}
				header_size = 10
			}

			// Oversized frame: protocol violation — disconnect rather than
			// buffering unbounded data.
			if payload_len > WS_MAX_PAYLOAD {
				ws.state = .Disconnected
				ws.running = false
				return
			}

			mask_offset := header_size
			if masked {
				header_size += 4
			}

			total_frame := header_size + payload_len
			if offset + total_frame > total do break

			payload_start := offset + header_size
			payload := buf[payload_start:payload_start + payload_len]

			if masked {
				mask_key := buf[offset + mask_offset:offset + mask_offset + 4]
				for i := 0; i < payload_len; i += 1 {
					payload[i] ~= mask_key[i % 4]
				}
			}

			switch opcode {
			case WS_OP_TEXT:
				msg_data := strings.clone(string(payload))
				sync.mutex_lock(&ws.recv_mutex)
				append(&ws.recv_queue, WS_Message{data = msg_data, binary = false})
				sync.mutex_unlock(&ws.recv_mutex)

			case WS_OP_BINARY:
				msg_data := strings.clone(string(payload))
				sync.mutex_lock(&ws.recv_mutex)
				append(&ws.recv_queue, WS_Message{data = msg_data, binary = true})
				sync.mutex_unlock(&ws.recv_mutex)

			case 0x0:
				// Continuation frames are unsupported (server never fragments
				// per PROTOCOL.md); treat as a protocol error.
				ws.state = .Disconnected
				ws.running = false
				return

			case WS_OP_PING:
				ws_send_frame(ws, WS_OP_PONG, payload)

			case WS_OP_CLOSE:
				ws.state = .Disconnected
				ws.running = false
				return
			}

			offset += total_frame
		}

		// Drop consumed bytes; keep any partial-frame tail for the next recv.
		if offset > 0 {
			remove_range(&acc, 0, offset)
		}
	}
}

// Send a text message over WebSocket.
ws_send :: proc(ws: ^WebSocket, data: string) -> bool {
	if ws.state != .Connected do return false
	return ws_send_frame(ws, WS_OP_TEXT, transmute([]u8)data)
}

// Send a binary message over WebSocket.
ws_send_binary :: proc(ws: ^WebSocket, data: []u8) -> bool {
	if ws.state != .Connected do return false
	if len(data) > WS_MAX_PAYLOAD do return false
	return ws_send_frame(ws, WS_OP_BINARY, data)
}

// Send a raw WebSocket frame.
ws_send_frame :: proc(ws: ^WebSocket, opcode: u8, payload: []u8) -> bool {
	// Reserve the whole frame up-front (header ≤14 bytes + payload) — large
	// payloads with per-byte append reallocation are slow.
	frame: [dynamic]u8
	defer delete(frame)
	reserve(&frame, 14 + len(payload))

	// FIN bit + opcode.
	append(&frame, 0x80 | opcode)

	// Payload length with mask bit set (client must mask).
	mask_bit: u8 = 0x80
	if len(payload) < 126 {
		append(&frame, mask_bit | u8(len(payload)))
	} else if len(payload) < 65536 {
		append(&frame, mask_bit | 126)
		append(&frame, u8(len(payload) >> 8))
		append(&frame, u8(len(payload) & 0xFF))
	} else {
		append(&frame, mask_bit | 127)
		for i := 7; i >= 0; i -= 1 {
			append(&frame, u8((len(payload) >> uint(i * 8)) & 0xFF))
		}
	}

	// Masking key (4 random bytes).
	mask_key: [4]u8
	for i in 0..<4 {
		mask_key[i] = u8(rand.uint32() & 0xFF)
	}
	append(&frame, mask_key[0])
	append(&frame, mask_key[1])
	append(&frame, mask_key[2])
	append(&frame, mask_key[3])

	// Masked payload: bulk-copy then XOR in place (no per-byte append).
	body := len(frame)
	resize(&frame, body + len(payload))
	copy(frame[body:], payload)
	for i := 0; i < len(payload); i += 1 {
		frame[body + i] ~= mask_key[i % 4]
	}

	// A single net.send may write only part of the frame; loop until the
	// whole frame is sent so the server never sees a truncated frame.
	// Serialize writes across threads.
	sync.mutex_lock(&ws.send_mutex)
	defer sync.mutex_unlock(&ws.send_mutex)
	total := 0
	for total < len(frame) {
		n, err := cnet.send(ws.socket, frame[total:])
		if err != nil do return false
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

// Close the WebSocket connection. Stops the worker thread: closing the
// socket unblocks a blocking recv (handshake or recv loop); a dial in flight
// fails on its own and the worker exits on running == false.
ws_close :: proc(ws: ^WebSocket) {
	ws.running = false

	sync.mutex_lock(&ws.sock_mutex)
	if ws.socket_open {
		if ws.state == .Connected {
			ws_send_frame(ws, WS_OP_CLOSE, nil)
		}
		cnet.close(ws.socket)
		ws.socket_open = false
	}
	sync.mutex_unlock(&ws.sock_mutex)
	ws.state = .Disconnected

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
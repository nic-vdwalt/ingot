#+build js
// Web WebSocket backend - same public API as net/ws.odin, but backed by the
// browser's native WebSocket (which handles the RFC 6455 framing/handshake/
// masking the native path implements by hand). Received messages are buffered
// JS-side and pulled into the shared recv model by ws_drain.
package ingotnet

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:time"

// JS bridge (provided by the client web shell). A socket is identified by an
// integer id; messages are queued in JS and pulled via ws_recv_*.
foreign import wsjs "ingot_ws"
@(default_calling_convention = "c")
foreign wsjs {
	ingot_ws_open :: proc(url: [^]byte, url_len: i32) -> i32 ---
	ingot_ws_send_text :: proc(id: i32, ptr: [^]byte, n: i32) -> i32 ---
	ingot_ws_send_binary :: proc(id: i32, ptr: [^]byte, n: i32) -> i32 ---
	ingot_ws_close :: proc(id: i32) ---
	ingot_ws_state :: proc(id: i32) -> i32 --- // 0 disc,1 conn,2 open,3 err
	ingot_ws_recv_len :: proc(id: i32) -> i32 --- // -1 none
	ingot_ws_recv_binary :: proc(id: i32) -> i32 --- // 1 if next msg is binary
	ingot_ws_recv_copy :: proc(id: i32, dst: [^]byte, cap: i32) -> i32 --- // dequeues
}

WS_State :: enum {
	Disconnected,
	Connecting,
	Reconnecting, // parity with the native backend (browser reconnect is its own concern)
	Connected,
	Error,
}

WS_OP_TEXT :: 0x1
WS_OP_BINARY :: 0x2
WS_MAX_PAYLOAD :: 1 << 20
WS_MAX_QUEUED_MESSAGES :: 1024
WS_MAX_QUEUED_BYTES :: 64 * 1024 * 1024
WS_CONNECT_TIMEOUT :: 10 * time.Second
WS_HANDSHAKE_TIMEOUT :: 5 * time.Second

// Timeouts are accepted for API parity with the native backend but unused:
// the browser owns connect/handshake timing for its WebSocket.
WS_Options :: struct {
	max_attempts:      int,
	connect_timeout:   time.Duration,
	handshake_timeout: time.Duration,
	ca_file:           string,
	headers:           []Http_Header,
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

WS_Message :: struct {
	data:   string,
	binary: bool,
}

Web_Socket :: struct {
	id:         i32,
	state:      WS_State,
	last_error: WS_Error,
	host:       string,
	port:       int,
	conn_gen:   int, // bumped on each transition into Connected (API parity)
	recv_queue: [dynamic]WS_Message,
	// API parity with the native backend so app code can set a wake hook on
	// every target; the browser's rAF-driven loop polls, so it is never called.
	// Event-driven web apps still see queued messages promptly: the gfx web
	// gate runs a floor frame every IDLE_MAX_WAIT seconds (_idle_web_gate),
	// which drains this socket even with no user input.
	wake:       proc "contextless" (),
}

ws_init :: proc() -> Web_Socket {
	ws: Web_Socket
	ws.id = -1
	ws.state = .Disconnected
	ws.recv_queue = make([dynamic]WS_Message)
	return ws
}

ws_start_connect :: proc(ws: ^Web_Socket, host: string, port: int, max_attempts: int) {
	url := fmt.tprintf("ws://%s:%d/ws", host, port)
	_ = ws_start_connect_url(ws, url, WS_Options{max_attempts = max_attempts})
}

ws_start_connect_url :: proc(ws: ^Web_Socket, raw_url: string, options: WS_Options = {}) -> bool {
	url, parse_err := ws_url_parse(raw_url)
	if parse_err != .None || options.ca_file != "" || len(options.headers) > 0 {
		ws.last_error = .Invalid_URL
		ws.state = .Error
		return false
	}
	ws.host = url.host
	ws.port = int(url.port)
	ws.state = .Connecting
	ws.last_error = .None
	bytes := transmute([]byte)raw_url
	ws.id = ingot_ws_open(raw_data(bytes), i32(len(bytes)))
	if ws.id < 0 {
		ws.last_error = .Connect
		ws.state = .Error
		return false
	}
	return true
}

// ws_poll_state refreshes ws.state from the JS socket.
@(private = "file")
ws_poll_state :: proc(ws: ^Web_Socket) {
	assert(ws != nil, "ws_poll_state: nil ws")
	if ws.id < 0 do return
	prev := ws.state
	switch ingot_ws_state(ws.id) {
	case 0:
		ws.state = .Disconnected
	case 1:
		ws.state = .Connecting
	case 2:
		ws.state = .Connected
	case:
		ws.state = .Error
	}
	// Bump the generation on each transition into Connected so consumers can
	// re-establish subscriptions, mirroring the native backend.
	if ws.state == .Connected && prev != .Connected {
		ws.conn_gen += 1
	}
}

// ws_conn_gen mirrors the native accessor (see net/ws.odin).
ws_conn_gen :: proc(ws: ^Web_Socket) -> int {
	ws_poll_state(ws)
	return ws.conn_gen
}

// ws_state mirrors the native accessor; the web backend is single-threaded,
// so it just refreshes from the JS socket and returns the field.
ws_state :: proc(ws: ^Web_Socket) -> WS_State {
	ws_poll_state(ws)
	return ws.state
}

ws_error :: proc(ws: ^Web_Socket) -> WS_Error {
	return ws.last_error
}

ws_send :: proc(ws: ^Web_Socket, data: string) -> bool {
	ws_poll_state(ws)
	if ws.state != .Connected || ws.id < 0 do return false
	b := transmute([]byte)data
	if len(b) > WS_MAX_PAYLOAD do return false
	return ingot_ws_send_text(ws.id, raw_data(b), i32(len(b))) == 0
}

ws_send_binary :: proc(ws: ^Web_Socket, data: []u8) -> bool {
	ws_poll_state(ws)
	if ws.state != .Connected || ws.id < 0 do return false
	if len(data) > WS_MAX_PAYLOAD do return false
	return ingot_ws_send_binary(ws.id, raw_data(data), i32(len(data))) == 0
}

// ws_drain pulls all JS-queued messages into temp-allocated WS_Message slices.
// Each message's `data` is heap-allocated and owned by the caller.
ws_drain :: proc(ws: ^Web_Socket) -> []WS_Message {
	ws_poll_state(ws)
	if ws.id < 0 do return nil

	msgs: [dynamic]WS_Message
	msgs.allocator = context.temp_allocator
	message_count := 0
	byte_count := 0
	for message_count < WS_MAX_QUEUED_MESSAGES && byte_count <= WS_MAX_QUEUED_BYTES {
		n := ingot_ws_recv_len(ws.id)
		if n < 0 do break
		if n > WS_MAX_PAYLOAD do break
		is_bin := ingot_ws_recv_binary(ws.id) == 1
		if n == 0 {
			got := ingot_ws_recv_copy(ws.id, nil, 0)
			if got != 0 {
				ws.state = .Error
				break
			}
			append(&msgs, WS_Message{data = "", binary = is_bin})
			message_count += 1
			continue
		}
		buf := make([]byte, int(n))
		ensure(len(buf) == int(n))
		got := ingot_ws_recv_copy(ws.id, raw_data(buf), i32(len(buf)))
		if got != n {
			delete(buf)
			ws.state = .Error
			break
		}
		append(&msgs, WS_Message{data = string(buf), binary = is_bin})
		message_count += 1
		byte_count += int(got)
	}
	if len(msgs) == 0 do return nil
	return msgs[:]
}

ws_has_pending :: proc(ws: ^Web_Socket) -> bool {
	if ws.id < 0 do return false
	return ingot_ws_recv_len(ws.id) >= 0
}

// ws_recv_dropped mirrors the native accessor. The browser buffers received
// messages without a drop-oldest cap on the Odin side, so this is always 0.
ws_recv_dropped :: proc(ws: ^Web_Socket) -> u64 {
	assert(ws != nil, "ws_recv_dropped: nil ws")
	return 0
}

ws_close :: proc(ws: ^Web_Socket) {
	assert(ws != nil, "ws_close: nil ws")
	if ws.id >= 0 {
		ingot_ws_close(ws.id)
		ws.id = -1
	}
	ws.state = .Disconnected
	for msg in ws.recv_queue do delete(msg.data)
	delete(ws.recv_queue)
	ws.recv_queue = nil
}

// keep imports referenced
_ :: runtime
_ :: strings

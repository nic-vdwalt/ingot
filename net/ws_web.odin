#+build js
// Web WebSocket backend — same public API as net/ws.odin, but backed by the
// browser's native WebSocket (which handles the RFC 6455 framing/handshake/
// masking the native path implements by hand). Received messages are buffered
// JS-side and pulled into the shared recv model by ws_drain.
package ingotnet

import "base:runtime"
import "core:fmt"
import "core:strings"

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

WS_Message :: struct {
	data:   string,
	binary: bool,
}

WebSocket :: struct {
	id:         i32,
	state:      WS_State,
	host:       string,
	port:       int,
	conn_gen:   int, // bumped on each transition into Connected (API parity)
	recv_queue: [dynamic]WS_Message,
	// API parity with the native backend so app code can set a wake hook on
	// every target; the browser's rAF-driven loop polls, so it is never called.
	wake:       proc "contextless" (),
}

ws_init :: proc() -> WebSocket {
	ws: WebSocket
	ws.id = -1
	ws.state = .Disconnected
	ws.recv_queue = make([dynamic]WS_Message)
	return ws
}

// ws_start_connect opens a browser WebSocket to ws://host:port/ws. The browser
// dials + upgrades asynchronously; the caller polls ws.state (updated in
// ws_drain / ws_poll_state). max_attempts is ignored (the browser handles it).
ws_start_connect :: proc(ws: ^WebSocket, host: string, port: int, max_attempts: int) {
	ws.host = host
	ws.port = port
	ws.state = .Connecting
	url := fmt.tprintf("ws://%s:%d/ws", host, port)
	ub := transmute([]byte)url
	ws.id = ingot_ws_open(raw_data(ub), i32(len(ub)))
	if ws.id < 0 {
		ws.state = .Error
	}
}

// ws_poll_state refreshes ws.state from the JS socket.
@(private = "file")
ws_poll_state :: proc(ws: ^WebSocket) {
	if ws.id < 0 {ws.state = .Error; return}
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
ws_conn_gen :: proc(ws: ^WebSocket) -> int {
	ws_poll_state(ws)
	return ws.conn_gen
}

// ws_state mirrors the native accessor; the web backend is single-threaded,
// so it just refreshes from the JS socket and returns the field.
ws_state :: proc(ws: ^WebSocket) -> WS_State {
	ws_poll_state(ws)
	return ws.state
}

ws_send :: proc(ws: ^WebSocket, data: string) -> bool {
	ws_poll_state(ws)
	if ws.state != .Connected || ws.id < 0 do return false
	b := transmute([]byte)data
	return ingot_ws_send_text(ws.id, raw_data(b), i32(len(b))) == 0
}

ws_send_binary :: proc(ws: ^WebSocket, data: []u8) -> bool {
	ws_poll_state(ws)
	if ws.state != .Connected || ws.id < 0 do return false
	if len(data) > WS_MAX_PAYLOAD do return false
	return ingot_ws_send_binary(ws.id, raw_data(data), i32(len(data))) == 0
}

// ws_drain pulls all JS-queued messages into temp-allocated WS_Message slices.
// Each message's `data` is heap-allocated and owned by the caller.
ws_drain :: proc(ws: ^WebSocket) -> []WS_Message {
	ws_poll_state(ws)
	if ws.id < 0 do return nil

	msgs: [dynamic]WS_Message
	msgs.allocator = context.temp_allocator
	for {
		n := ingot_ws_recv_len(ws.id)
		if n < 0 do break
		is_bin := ingot_ws_recv_binary(ws.id) == 1
		buf := make([]byte, int(n) if n > 0 else 0)
		got := ingot_ws_recv_copy(ws.id, raw_data(buf) if n > 0 else nil, i32(len(buf)))
		if got < 0 {if len(buf) > 0 do delete(buf); break}
		append(&msgs, WS_Message{data = string(buf[:int(got)]), binary = is_bin})
	}
	if len(msgs) == 0 do return nil
	return msgs[:]
}

ws_has_pending :: proc(ws: ^WebSocket) -> bool {
	if ws.id < 0 do return false
	return ingot_ws_recv_len(ws.id) >= 0
}

ws_close :: proc(ws: ^WebSocket) {
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

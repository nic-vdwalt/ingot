#+build !js
package ingotnet

// Tests for the deterministic simulated WebSocket transport. Only compiled
// when the sim is enabled:
//
//	odin test net -collection:ingot=. -define:INGOT_WS_SIM=true \
//	  -define:ODIN_TEST_THREADS=1
//
// ODIN_TEST_THREADS=1 is required, not a preference. ws_sim_load resets one
// process-global tape (g_ws_sim); its mutex makes each call atomic but does
// not protect a load-then-consume sequence, so concurrent tests overwrite each
// other's tape and fail intermittently. scripts/test.sh and fuzz/run.sh pin
// the same value for the term fuzzers, for the same reason.

import "core:strings"
import "base:runtime"
import "core:sync"
import "core:testing"
import "core:time"

_ :: strings
_ :: runtime
_ :: sync
_ :: testing
_ :: time

when INGOT_WS_SIM {
	ws_sim_expect_delivery :: proc(
		t: ^testing.T,
		events: []Ws_Sim_Event,
		expected: []string,
		generations := 1,
	) {
		context.allocator = runtime.heap_allocator()
		ws_sim_load(events, 7)
		ws := ws_init()
		defer ws_close(&ws)
		ws_start_connect(&ws, "sim", 1, 2)
		received := 0
		started := time.now()
		for time.since(started) < 3 * time.Second {
			for message in ws_drain(&ws) {
				if received < len(expected) {
					testing.expect_value(t, message.data, expected[received])
				}
				received += 1
				delete(message.data, runtime.heap_allocator())
			}
			if !sync.atomic_load(&ws.running) do break
			if received >= len(expected) && ws_conn_gen(&ws) >= generations {
				if time.since(started) >= 100 * time.Millisecond do break
			}
			time.sleep(time.Millisecond)
		}
		for message in ws_drain(&ws) {
			if received < len(expected) {
				testing.expect_value(t, message.data, expected[received])
			}
			received += 1
			delete(message.data, runtime.heap_allocator())
		}
		testing.expect_value(t, received, len(expected))
		testing.expect_value(t, ws_conn_gen(&ws), generations)
	}

	@(test)
	ws_sim_coalesced_delivery :: proc(t: ^testing.T) {
		ws_sim_expect_delivery(t, {.Handshake_Frame, .Timeout}, {"first"})
		ws_sim_expect_delivery(t, {.Handshake_Frame, .Cut}, {"first"})
		ws_sim_expect_delivery(t, {.Handshake_Multiple}, {"first", "second"})
		ws_sim_expect_delivery(t, {.Handshake_Split_Header}, {"first"})
		ws_sim_expect_delivery(t, {.Handshake_Split_Payload}, {"first"})
		ws_sim_expect_delivery(t, {.Handshake_Frame_And_Partial}, {"first", "second"})
		ws_sim_expect_delivery(t, {.Handshake_Invalid_Frame, .Handshake_Invalid_Frame}, {}, 0)
		ws_sim_expect_delivery(t, {.Handshake_Ping_Frame}, {"first"})
		testing.expect_value(t, ws_sim_pongs_sent(), 1)
		ws_sim_expect_delivery(t, {.Handshake_Cut, .Handshake_Frame}, {"first"})
		ws_sim_expect_delivery(t, {.Handshake_Close}, {})
		ws_sim_expect_delivery(t, {.Server_Close}, {})
		ws_sim_expect_delivery(
			t,
			{.Handshake_Frame, .Cut, .Handshake_Close},
			{"first"},
			2,
		)
	}

	@(test)
	ws_sim_coalesced_small_buffer :: proc(t: ^testing.T) {
		ws_sim_load({.Handshake_Frame}, 7)
		transport := ws_sim_transport(.TCP)
		request := transmute([]u8)string("Sec-WebSocket-Key: test-key\r\n")
		_, err := ws_net_send(&transport, request)
		testing.expect_value(t, err, Ws_Net_Err.None)
		buffer: [4]u8
		wire: [512]u8
		total := 0
		for total < len(wire) - len(buffer) {
			count, recv_err := ws_net_recv(&transport, buffer[:])
			if recv_err == .Timeout do break
			testing.expect_value(t, recv_err, Ws_Net_Err.None)
			if count <= 0 do break
			total += copy(wire[total:], buffer[:count])
		}
		response := string(wire[:total])
		testing.expect(t, ws_handshake_response_valid(response, "test-key"))
		header_end := strings.index(response, "\r\n\r\n")
		if header_end < 0 do return
		frame, consumed, status := ws_parse_frame(wire[header_end + 4:total])
		testing.expect_value(t, consumed, 7)
		testing.expect(t, status != .Need_More && status != .Too_Big)
		testing.expect_value(t, string(frame.payload), "first")
		testing.expect_value(t, ws_sim_frames_served(), 1)
	}

	@(test)
	ws_sim_handshake_contract :: proc(t: ^testing.T) {
		buffer: [256]u8
		ws_sim_load({.Frame_Text}, 1)
		transport := ws_sim_transport(.TCP)
		_, _ = ws_net_send(&transport, transmute([]u8)string("Sec-WebSocket-Key: test-key\r\n"))
		count, err, handled := sim_recv_handshake(buffer[:])
		testing.expect(t, handled)
		testing.expect_value(t, err, Ws_Net_Err.None)
		testing.expect(t, strings.has_prefix(string(buffer[:count]), "HTTP/1.1 101"))
		count, err = sim_recv_event(.Frame_Text, buffer[:])
		testing.expect(t, count > 0)
		testing.expect_value(t, err, Ws_Net_Err.None)

		ws_sim_load({.Handshake_Garbage}, 1)
		_, _ = ws_net_send(&transport, transmute([]u8)string("Sec-WebSocket-Key: test-key\r\n"))
		count, err, handled = sim_recv_handshake(buffer[:])
		testing.expect(t, handled)
		testing.expect_value(t, err, Ws_Net_Err.None)
		testing.expect(t, strings.has_prefix(string(buffer[:count]), "HTTP/1.1 200"))

		ws_sim_load({.Handshake_Cut}, 1)
		_, _ = ws_net_send(&transport, transmute([]u8)string("Sec-WebSocket-Key: test-key\r\n"))
		_, err, handled = sim_recv_handshake(buffer[:])
		testing.expect(t, handled)
		testing.expect_value(t, err, Ws_Net_Err.Other)
	}

	@(test)
	ws_sim_split_and_fragment_contract :: proc(t: ^testing.T) {
		buffer: [256]u8
		ws_sim_load({.Frame_Split}, 7)
		first, err := sim_recv_event(.Frame_Split, buffer[:])
		testing.expect_value(t, err, Ws_Net_Err.None)
		testing.expect(t, first > 0)
		second, tail_err, handled := sim_recv_split_tail(buffer[:])
		testing.expect(t, handled)
		testing.expect_value(t, tail_err, Ws_Net_Err.None)
		testing.expect(t, second > 0)
		testing.expect_value(t, ws_sim_frames_served(), 1)

		ws_sim_load({.Frame_Fragmented}, 7)
		first, err = sim_recv_event(.Frame_Fragmented, buffer[:])
		testing.expect_value(t, err, Ws_Net_Err.None)
		testing.expect(t, first > 0 && buffer[0] == WS_OP_TEXT)
		second, _, handled = sim_recv_split_tail(buffer[:])
		testing.expect(t, handled && second > 0)
		testing.expect_value(t, buffer[0], u8(0x80 | WS_OP_CONTINUATION))
	}

	@(test)
	ws_sim_event_and_burst_contract :: proc(t: ^testing.T) {
		buffer: [256]u8
		ws_sim_load({.Frame_Burst}, 11)
		count, err := sim_recv_event(.Frame_Burst, buffer[:])
		testing.expect_value(t, err, Ws_Net_Err.None)
		testing.expect(t, count > 0)
		_, _, handled := sim_recv_pending_burst(buffer[:])
		testing.expect(t, handled)
		testing.expect_value(t, ws_sim_frames_served(), 2)

		count, err = sim_recv_event(.Frame_Ping, buffer[:])
		testing.expect_value(t, err, Ws_Net_Err.None)
		testing.expect(t, count == 2 && buffer[0] == u8(0x80 | WS_OP_PING))
		_, err = sim_recv_event(.Cut, buffer[:])
		testing.expect_value(t, err, Ws_Net_Err.Other)
		_, err = sim_recv_event(.Timeout, buffer[:])
		testing.expect_value(t, err, Ws_Net_Err.Timeout)
	}

	@(test)
	ws_sim_tls_contract :: proc(t: ^testing.T) {
		ws_sim_load({.TLS_Fail}, 1)
		_, err := ws_net_dial_tls("example.test", 443, "", time.Second)
		testing.expect_value(t, err, Ws_Net_Err.TLS)
		ws_sim_load({.TLS_Valid, .Frame_Text}, 1)
		transport, valid_err := ws_net_dial_tls("example.test", 443, "", time.Second)
		testing.expect_value(t, valid_err, Ws_Net_Err.None)
		testing.expect(t, transport.open)
		testing.expect_value(t, transport.kind, Ws_Transport_Kind.TLS)
	}
}

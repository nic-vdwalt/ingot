#+build !js
package ingotnet

import "core:strings"
import "core:testing"
import "core:time"

_ :: strings
_ :: testing

when INGOT_WS_SIM {
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

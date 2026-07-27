#+build !js
package ingotnet

import "core:c"
import "core:fmt"
import cnet "core:net"
import "core:strings"
import "core:time"

INGOT_WS_SIM :: #config(INGOT_WS_SIM, false)

when INGOT_WS_SIM {
	WS_TIME_SCALE :: 0.001
} else {
	WS_TIME_SCALE :: 1.0
}

ws_scaled :: proc(d: time.Duration) -> time.Duration {
	when INGOT_WS_SIM {
		scaled := time.Duration(f64(d) * WS_TIME_SCALE)
		return max(scaled, time.Millisecond)
	} else {
		return d
	}
}

Ws_Net_Err :: enum u8 {
	None,
	Timeout,
	Cancelled,
	TLS,
	Other,
}

Ws_Transport_Kind :: enum u8 {
	TCP,
	TLS,
}

Ws_Transport :: struct {
	kind:        Ws_Transport_Kind,
	socket:      cnet.TCP_Socket,
	curl_handle: ^Ws_Curl,
	open:        bool,
}

when !INGOT_WS_SIM {
	ws_net_resolve :: proc(host: string, port: int) -> (cnet.Endpoint, bool) {
		if addr, ok := cnet.parse_ip4_address(host); ok {
			return cnet.Endpoint{address = addr, port = port}, true
		}
		endpoint, err := cnet.resolve_ip4(host)
		if err != nil do return {}, false
		endpoint.port = port
		return endpoint, true
	}

	ws_net_dial :: proc(endpoint: cnet.Endpoint) -> (Ws_Transport, Ws_Net_Err) {
		socket, err := cnet.dial_tcp(endpoint)
		if err != nil do return {}, .Other
		return Ws_Transport{kind = .TCP, socket = socket, open = true}, .None
	}

	@(private = "file")
	ws_tls_configure :: proc(
		handle: ^Ws_Curl,
		host: string,
		port: u16,
		ca_file: string,
		connect_timeout: time.Duration,
	) -> bool {
		url := fmt.tprintf("https://%s:%d/", host, port)
		url_c, url_err := strings.clone_to_cstring(url, context.temp_allocator)
		if url_err != nil do return false
		if ws_curl_easy_setopt(handle, WS_CURL_URL, url_c) != .OK do return false
		if ws_curl_easy_setopt(handle, WS_CURL_CONNECT_ONLY, c.long(1)) != .OK do return false
		if ws_curl_easy_setopt(handle, WS_CURL_SSL_VERIFYPEER, c.long(1)) != .OK do return false
		if ws_curl_easy_setopt(handle, WS_CURL_SSL_VERIFYHOST, c.long(2)) != .OK do return false
		if ws_curl_easy_setopt(handle, WS_CURL_DISALLOW_USERNAME_IN_URL, c.long(1)) != .OK {
			return false
		}
		milliseconds := c.long(connect_timeout / time.Millisecond)
		if ws_curl_easy_setopt(handle, WS_CURL_CONNECTTIMEOUT_MS, milliseconds) != .OK {
			return false
		}
		if ca_file != "" {
			ca_c, ca_err := strings.clone_to_cstring(ca_file, context.temp_allocator)
			if ca_err != nil do return false
			if ws_curl_easy_setopt(handle, WS_CURL_CAINFO, ca_c) != .OK do return false
		}
		return true
	}

	ws_net_dial_tls :: proc(
		host: string,
		port: u16,
		ca_file: string,
		connect_timeout: time.Duration,
	) -> (
		Ws_Transport,
		Ws_Net_Err,
	) {
		if ws_curl_global_init(WS_CURL_GLOBAL_ALL) != .OK do return {}, .TLS
		handle := ws_curl_easy_init()
		if handle == nil do return {}, .TLS
		if !ws_tls_configure(handle, host, port, ca_file, connect_timeout) {
			ws_curl_easy_cleanup(handle)
			return {}, .TLS
		}
		result := ws_curl_easy_perform(handle)
		if result != .OK {
			ws_curl_easy_cleanup(handle)
			if result == .OPERATION_TIMEDOUT do return {}, .Timeout
			return {}, .TLS
		}
		return Ws_Transport{kind = .TLS, curl_handle = handle, open = true}, .None
	}

	ws_net_send :: proc(transport: ^Ws_Transport, data: []u8) -> (int, Ws_Net_Err) {
		if transport == nil || !transport.open do return 0, .Other
		if transport.kind == .TCP {
			count, err := cnet.send(transport.socket, data)
			if err != nil do return count, .Other
			ensure(count >= 0 && count <= len(data))
			return count, .None
		}
		count: c.size_t
		result := ws_curl_easy_send(
			transport.curl_handle,
			raw_data(data),
			c.size_t(len(data)),
			&count,
		)
		if result == .AGAIN do return int(count), .Timeout
		if result != .OK do return int(count), .Other
		ensure(count <= c.size_t(len(data)))
		return int(count), .None
	}

	ws_net_recv :: proc(transport: ^Ws_Transport, buf: []u8) -> (int, Ws_Net_Err) {
		if transport == nil || !transport.open do return 0, .Other
		if transport.kind == .TCP {
			count, err := cnet.recv(transport.socket, buf)
			if err != nil {
				if err == .Timeout || err == .Would_Block do return count, .Timeout
				return count, .Other
			}
			ensure(count >= 0 && count <= len(buf))
			return count, .None
		}
		count: c.size_t
		result := ws_curl_easy_recv(
			transport.curl_handle,
			raw_data(buf),
			c.size_t(len(buf)),
			&count,
		)
		if result == .AGAIN do return int(count), .Timeout
		if result != .OK do return int(count), .Other
		ensure(count <= c.size_t(len(buf)))
		return int(count), .None
	}

	ws_net_close :: proc(transport: ^Ws_Transport) {
		if transport == nil || !transport.open do return
		transport.open = false
		if transport.kind == .TCP {
			cnet.close(transport.socket)
		} else if transport.curl_handle != nil {
			ws_curl_easy_cleanup(transport.curl_handle)
			transport.curl_handle = nil
		}
	}

	ws_net_set_recv_timeout :: proc(transport: ^Ws_Transport, duration: time.Duration) {
		if transport == nil || !transport.open do return
		if transport.kind == .TCP {
			_ = cnet.set_option(transport.socket, .Receive_Timeout, duration)
		}
	}
}

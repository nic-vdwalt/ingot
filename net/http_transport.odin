#+build !js
package ingotnet

import cnet "core:net"
import "core:time"

HTTP_STRESS :: #config(INGOT_HTTP_STRESS, false)

when !HTTP_STRESS {
	http_net_dial :: proc(ep: cnet.Endpoint) -> (cnet.TCP_Socket, bool) {
		sock, err := cnet.dial_tcp(ep)
		return sock, err == nil
	}

	http_net_send :: proc(sock: cnet.TCP_Socket, data: []u8) -> (int, bool) {
		n, err := cnet.send(sock, data)
		return n, err == nil
	}

	http_net_recv :: proc(sock: cnet.TCP_Socket, data: []u8) -> (int, bool) {
		n, err := cnet.recv(sock, data)
		return n, err == nil
	}

	http_net_close :: proc(sock: cnet.TCP_Socket) {
		cnet.close(sock)
	}

	http_net_set_recv_timeout :: proc(sock: cnet.TCP_Socket, duration: time.Duration) {
		_ = cnet.set_option(sock, .Receive_Timeout, duration)
	}
}

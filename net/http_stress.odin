#+build !js
package ingotnet

import cnet "core:net"
import "core:sync"
import "core:time"

_ :: cnet
_ :: sync
_ :: time

when HTTP_STRESS {
	Http_Stress_State :: struct {
		handle_seq:  i64,
		requests:    int,
		completions: int,
		closes:      int,
		partial:     [FETCH_MAXIMUM_PENDING * 2]bool,
		mutex:       sync.Mutex,
	}

	@(private = "file")
	http_stress: Http_Stress_State

	http_stress_reset :: proc() {
		sync.mutex_lock(&http_stress.mutex)
		http_stress.handle_seq = 0
		http_stress.requests = 0
		http_stress.completions = 0
		http_stress.closes = 0
		http_stress.partial = {}
		sync.mutex_unlock(&http_stress.mutex)
	}

	http_stress_counts :: proc() -> (requests, completions, closes: int) {
		sync.mutex_lock(&http_stress.mutex)
		requests = http_stress.requests
		completions = http_stress.completions
		closes = http_stress.closes
		sync.mutex_unlock(&http_stress.mutex)
		return
	}

	http_net_dial :: proc(ep: cnet.Endpoint) -> (cnet.TCP_Socket, bool) {
		sync.mutex_lock(&http_stress.mutex)
		http_stress.handle_seq += 1
		handle := http_stress.handle_seq
		sync.mutex_unlock(&http_stress.mutex)
		return cnet.TCP_Socket(handle), true
	}

	http_net_send :: proc(sock: cnet.TCP_Socket, data: []u8) -> (int, bool) {
		handle := int(i64(sock))
		sync.mutex_lock(&http_stress.mutex)
		if handle <= 0 || handle > len(http_stress.partial) {
			sync.mutex_unlock(&http_stress.mutex)
			return 0, false
		}
		first := !http_stress.partial[handle - 1]
		http_stress.partial[handle - 1] = true
		if first do http_stress.requests += 1
		sync.mutex_unlock(&http_stress.mutex)
		return max(len(data) / 2, 1) if len(data) > 1 else len(data), true
	}

	http_net_recv :: proc(sock: cnet.TCP_Socket, data: []u8) -> (int, bool) {
		handle := int(i64(sock))
		sync.mutex_lock(&http_stress.mutex)
		if handle <= 0 || handle > len(http_stress.partial) {
			sync.mutex_unlock(&http_stress.mutex)
			return 0, false
		}
		if http_stress.partial[handle - 1] {
			http_stress.partial[handle - 1] = false
			http_stress.completions += 1
			sync.mutex_unlock(&http_stress.mutex)
			response := "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok"
			return copy(data, response), true
		}
		sync.mutex_unlock(&http_stress.mutex)
		return 0, true
	}

	http_net_close :: proc(sock: cnet.TCP_Socket) {
		sync.mutex_lock(&http_stress.mutex)
		http_stress.closes += 1
		sync.mutex_unlock(&http_stress.mutex)
	}

	http_net_set_recv_timeout :: proc(sock: cnet.TCP_Socket, duration: time.Duration) {
	}
}

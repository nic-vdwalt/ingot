package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:time"
import ingotnet "ingot:net"

main :: proc() {
	args := os.args
	if len(args) != 5 {
		fmt.eprintln("usage: wss_fixture URL CA_FILE EXPECTED_ERROR EXPECT_MESSAGE")
		os.exit(2)
	}
	expected_value, parsed := strconv.parse_i64(args[3])
	if !parsed {
		fmt.eprintln("wss_fixture: invalid expected error")
		os.exit(2)
	}
	ws := ingotnet.ws_init()
	started := ingotnet.ws_start_connect_url(
		&ws,
		args[1],
		ingotnet.WS_Options {
			max_attempts = 1,
			connect_timeout = 3 * time.Second,
			handshake_timeout = 3 * time.Second,
			ca_file = args[2],
		},
	)
	if !started {
		fmt.eprintln("wss_fixture: connection did not start")
		os.exit(1)
	}
	started_at := time.now()
	for time.since(started_at) < 5 * time.Second {
		state := ingotnet.ws_state(&ws)
		if state == .Connected {
			if args[4] == "1" {
				for !ingotnet.ws_has_pending(&ws) && time.since(started_at) < 5 * time.Second {
					time.sleep(10 * time.Millisecond)
				}
				messages := ingotnet.ws_drain(&ws)
				if len(messages) != 1 || messages[0].data != "secure" {
					fmt.eprintln("wss_fixture: secure message mismatch")
					os.exit(1)
				}
				for message in messages do delete(message.data)
			}
			ingotnet.ws_close(&ws)
			return
		}
		if state == .Error || state == .Disconnected {
			actual := int(ingotnet.ws_error(&ws))
			if actual == int(expected_value) {
				ingotnet.ws_close(&ws)
				return
			}
			fmt.eprintln("wss_fixture: unexpected error", actual)
			os.exit(1)
		}
		time.sleep(10 * time.Millisecond)
	}
	fmt.eprintln("wss_fixture: timed out")
	os.exit(1)
}

#+build !js
package main

import "core:fmt"
import "core:os"

when MAP_CAPTURE {
	map_capture_main :: proc() {
		fmt.eprintln("api-map capture requires the native media capture target")
		os.exit(1)
	}
}

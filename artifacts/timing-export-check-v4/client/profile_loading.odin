package main

import "core:os"
import "core:fmt"

profile_loading_publish :: proc() {
	when PROFILE_ENABLED {
		if os.get_env("FORGE_SCENARIO", context.temp_allocator) == "" do return
		path := os.get_env("AESIR_TELEMETRY", context.temp_allocator)
		if path == "" do return
		text := `{"k":"investigation","v":1,"phase":"loading"}`
		_ = os.write_entire_file(fmt.tprintf("%s.scenario", path), transmute([]u8)text)
	}
}

#+build !js
package main

import rl "ingot:gfx"

import "core:encoding/json"
import "core:fmt"
import "core:os"

telemetry_diagnostics_shutdown :: proc() {
	if !PROFILE_ENABLED || !rl.GPU_TIMING_DIAGNOSTICS do return
	{
		path := os.get_env(TELEMETRY_ENV, context.temp_allocator)
		if path == "" do return
		snapshot := rl.context_gpu_timing_diagnostics(rl.default_context())
		payload := struct {
			version: u32,
			failures: []rl.Gpu_Timing_Diagnostic,
			dropped: u64,
			encoder_overflow: u64,
			missing_encoder: u64,
			categories: []rl.Gpu_Timing_Diagnostic_Category,
			category_overflow: u64,
		}{
			version = 3,
			failures = snapshot.failures[:snapshot.failure_count],
			dropped = snapshot.dropped,
			encoder_overflow = snapshot.encoder_overflow,
			missing_encoder = snapshot.missing_encoder,
			categories = snapshot.categories[:snapshot.category_count],
			category_overflow = snapshot.category_overflow,
		}
		bytes, encode_error := json.marshal(payload, allocator = context.temp_allocator)
		if encode_error != nil {
			fmt.eprintln("timing diagnostic encoding failed:", encode_error)
			return
		}
		if os.write_entire_file(fmt.tprintf("%s.timing.json", path), bytes) != nil {
			fmt.eprintln("timing diagnostic write failed")
		}
	}
}

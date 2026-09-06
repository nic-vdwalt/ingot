#+build js
package main

// Web build: there is no filesystem in the browser sandbox and no aesir to
// tail a sidecar, so telemetry is compiled away to nothing. The signatures
// match telemetry.odin so the call sites in game_frame need no build tags.

Telemetry :: struct {
	open:    bool,
	next_at: f64,
	frame:   u64,
}

telemetry_init :: proc(value: ^Telemetry) {
	assert(value != nil, "telemetry_init: nil telemetry")
}

telemetry_shutdown :: proc(value: ^Telemetry) {
	assert(value != nil, "telemetry_shutdown: nil telemetry")
}

telemetry_publish :: proc(value: ^Telemetry, profiler: ^Profiler, now: f64) {
	assert(value != nil && profiler != nil, "telemetry_publish: nil argument")
}

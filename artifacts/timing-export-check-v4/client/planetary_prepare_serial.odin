#+build js
package main

// JS fallback: no threads on wasm, so nothing is prepared ahead and every
// tick runs synchronously. Same API as the native async path.

import shared "../shared"

Planetary_Prepare :: struct {
	shadow:    ^shared.Planetary_State,
	scratch:   ^shared.Planetary_State,
	commits:   u64,
	fallbacks: u64,
	peak_ms:   f64,
}

planetary_prepare_active :: proc(prepare: ^Planetary_Prepare) -> bool {
	assert(prepare != nil, "planetary_prepare_active: nil prepare")
	return false
}

planetary_prepare_init :: proc(prepare: ^Planetary_Prepare, world: ^shared.World) -> bool {
	assert(prepare != nil && world != nil, "planetary_prepare_init: nil argument")
	prepare^ = {}
	return false
}

planetary_prepare_deinit :: proc(prepare: ^Planetary_Prepare) {
	assert(prepare != nil, "planetary_prepare_deinit: nil prepare")
	prepare^ = {}
}

planetary_prepare_begin :: proc(prepare: ^Planetary_Prepare, tick: u64) {
	assert(prepare != nil, "planetary_prepare_begin: nil prepare")
}

planetary_prepare_wait :: proc(prepare: ^Planetary_Prepare) {
	assert(prepare != nil, "planetary_prepare_wait: nil prepare")
}

planetary_prepare_take :: proc(prepare: ^Planetary_Prepare, tick: u64) -> bool {
	assert(prepare != nil, "planetary_prepare_take: nil prepare")
	return false
}

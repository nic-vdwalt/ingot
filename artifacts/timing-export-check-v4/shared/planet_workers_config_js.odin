#+build js
package shared

// No threads on wasm: every planetary job runs inline.
planet_workers_default_count :: proc() -> int {
	return 0
}

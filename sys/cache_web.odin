#+build js
package sys

cache_dir :: proc(app: string, allocator := context.temp_allocator) -> (dir: string, ok: bool) {
	assert(len(app) > 0, "cache_dir: empty app")
	_ = allocator
	return "", false
}

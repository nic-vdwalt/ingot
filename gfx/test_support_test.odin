#+build !js
package gfx

import "core:sync"

INGOT_GFX_EXPECTED_ASSERTS :: #config(INGOT_GFX_EXPECTED_ASSERTS, false)

@(private)
gfx_shared_test_guard: sync.Mutex

gfx_shared_test_lock :: proc() {
	sync.mutex_lock(&gfx_shared_test_guard)
}

gfx_shared_test_unlock :: proc() {
	sync.mutex_unlock(&gfx_shared_test_guard)
}

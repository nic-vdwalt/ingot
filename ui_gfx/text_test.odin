#+build !js
package ui_gfx

import "core:testing"
import "ingot:ui"

@(test)
test_adapter_attach_runtime_installs_text_backend :: proc(t: ^testing.T) {
	adapter: Adapter
	adapter_init(&adapter)
	defer adapter_destroy(&adapter)
	runtime: ui.Ui_Runtime
	ui.ui_runtime_init(&runtime)
	defer ui.ui_runtime_destroy(&runtime)

	adapter_attach_runtime(&adapter, &runtime)

	testing.expect(t, ui.text_backend_valid(runtime.text_backend))
	testing.expect(t, runtime.text_backend.data == &adapter)
}

#+build !js
package ui_gfx

import "core:testing"
import rl "ingot:gfx"
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

@(test)
test_adapter_value_conversions_preserve_components :: proc(t: ^testing.T) {
	ui_vector := ui.Vec2{12.5, -3.25}
	gfx_vector := vec_to_gfx(ui_vector)
	vector_round_trip := vec_to_ui(gfx_vector)
	testing.expect_value(t, gfx_vector, rl.Vector2{12.5, -3.25})
	testing.expect_value(t, vector_round_trip, ui_vector)

	rect := rect_to_gfx(ui.Rect{1.25, 2.5, 30.75, 40.5})
	testing.expect_value(t, rect, rl.Rectangle{1.25, 2.5, 30.75, 40.5})

	ui_color := ui.Color{17, 34, 51, 68}
	gfx_color := color_to_gfx(ui_color)
	color_round_trip := color_from_gfx(gfx_color)
	testing.expect_value(t, gfx_color, rl.Color{17, 34, 51, 68})
	testing.expect_value(t, color_round_trip, ui_color)
}

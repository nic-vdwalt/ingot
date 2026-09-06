#+build !js
package ui_gfx

import "core:testing"
import rl "ingot:gfx"
import "ingot:ui"

@(test)
test_adapter_attach_runtime_installs_text_backend :: proc(t: ^testing.T) {
	test_context_lock()
	defer test_context_unlock()
	adapter: Adapter
	adapter_init_context(&adapter, rl.default_context())
	defer adapter_destroy(&adapter)
	runtime: ui.Ui_Runtime
	ui.ui_runtime_init(&runtime)
	defer ui.ui_runtime_destroy(&runtime)

	adapter_attach_runtime(&adapter, &runtime)
	defer adapter_detach_runtime(&adapter, &runtime)

	testing.expect(t, ui.text_backend_valid(runtime.text_backend))
	testing.expect(t, ui.text_backend_has_metrics(runtime.text_backend))
	testing.expect(t, runtime.text_backend.data == &adapter)
	testing.expect(t, runtime.web_form.data == &adapter)
}

@(test)
test_adapter_metrics_rejects_an_unknown_font :: proc(t: ^testing.T) {
	adapter: Adapter
	adapter.initialized = true
	metrics, ok := adapter_metrics(&adapter, ui.Font_Id(1), 16)
	testing.expect(t, !ok)
	testing.expect_value(t, metrics, ui.Text_Metrics{})
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

@(test)
test_adapter_font_limit_returns_closest_font :: proc(t: ^testing.T) {
	adapter: Adapter
	adapter.initialized = true
	adapter.font_count = FONT_CAP
	for index in 0 ..< FONT_CAP {
		adapter.font_sizes[index] = i32(index + 1)
		adapter.fonts[index] = {
			glyphCount = 1,
			_atlas     = u32(index + 1),
		}
	}
	id := adapter_register_font(&adapter, 70, {glyphCount = 1, _atlas = 999})
	testing.expect_value(t, id, ui.Font_Id(FONT_CAP))
	testing.expect_value(t, adapter.font_count, FONT_CAP)
}

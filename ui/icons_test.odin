#+build !js
package ui

import "core:testing"

@(test)
standard_settings_icon_emits_geometry_without_text :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	backend: Test_Text_Backend_State
	ui_runtime_set_text_backend(
		&runtime,
		{data = &backend, font_for_size = test_text_font_for_size, measure = test_text_measure},
	)
	sem_enable(&runtime, true)
	output := new(Ui_Output)
	defer free(output)
	frame := Ui_Frame {
		output = output,
	}
	ui_frame_begin(&frame, &runtime)
	defer ui_frame_destroy(&frame)
	_ = icon_button_at(&frame, {10, 20, 28, 28}, .Settings, "Settings", widget = 7)
	geometry := 0
	text := 0
	for index in 0 ..< output.main.count {
		kind := output.main.commands[index].kind
		if kind == .Text || kind == .Codepoint {
			text += 1
		} else {
			geometry += 1
		}
	}
	testing.expect(t, geometry >= 11, "settings icon should emit button and gear geometry")
	testing.expect_value(t, text, 0)
	testing.expect_value(t, frame.semantics.cur.count, 1)
	testing.expect_value(t, sem_node_label(&frame.semantics.cur.nodes[0]), "Settings")
	ui_frame_end(&frame)
}

@(test)
icons_report_degenerate_rectangles :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	frame: Ui_Frame
	ui_frame_begin(&frame, &runtime)
	draw_icon_frame(&frame, .Settings, {0, 0, 0, 28}, {255, 255, 255, 255})
	testing.expect_value(t, frame.degenerate_drops, 1)
	ui_frame_end(&frame)
	ui_frame_destroy(&frame)
}

@(test)
unsupported_private_use_glyph_is_reported :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	backend: Test_Text_Backend_State
	ui_runtime_set_text_backend(&runtime, {
		data = &backend,
		font_for_size = test_text_font_for_size,
		measure = test_text_measure,
		has_glyph = proc(_: rawptr, _: Font_Id, value: rune) -> bool {return value < 0xE000},
	})
	output := new(Ui_Output)
	defer free(output)
	frame := Ui_Frame {
		output = output,
	}
	ui_frame_begin(&frame, &runtime)
	draw_codepoint_frame(&frame, 0xEAF8, 0, 0, 16, {255, 255, 255, 255})
	testing.expect_value(t, frame.unsupported_glyphs, 1)
	testing.expect_value(t, output.main.count, 0)
	ui_frame_end(&frame)
	ui_frame_destroy(&frame)
}

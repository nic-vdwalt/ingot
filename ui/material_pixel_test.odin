#+build !js
// Pixel style tests.
//
// These pin the three promises the Pixel theme makes: text is quantised to
// whole multiples of the pixel face's grid, a face switch invalidates every
// cached font, and pixel surfaces are built from plain rectangles within a
// fixed command bound.
package ui

import "core:testing"

@(test)
pixel_theme_selects_pixel_face_and_style :: proc(t: ^testing.T) {
	style := theme_pixel()
	testing.expect_value(t, style.font_face, Font_Face.Pixel)
	testing.expect_value(t, style.surface_style, Surface_Style.Pixel)
	testing.expect_value(t, style.bevel_light.a, u8(255))
	testing.expect_value(t, style.bevel_shade.a, u8(255))
	testing.expect(t, style.bevel_light != style.bevel_shade)
	others := [?]Theme {
		theme_dark(),
		theme_light(),
		theme_high_contrast(),
		theme_retro_orange(),
		theme_retro_orange_dark(),
		theme_retro_ingot(),
		theme_retro_ingot_dark(),
		theme_terra(),
	}
	for other in others {
		testing.expect_value(t, other.font_face, Font_Face.Mono)
		testing.expect_value(t, other.surface_style, Surface_Style.Smooth)
		testing.expect(t, other.bevel_light.a > 0 && other.bevel_shade.a > 0)
	}
}

@(test)
pixel_text_size_lands_on_whole_grids :: proc(t: ^testing.T) {
	Case :: struct {
		size:     i32,
		dpi:      f32,
		expected: i32,
	}
	cases := [?]Case {
		{16, 1, 16},
		{20, 1, 16},
		{12, 1, 16},
		{4, 1, 16},
		{28, 1, 32},
		{16, 2, 16},
		{12, 2, 16},
		{8, 2, 8},
		{20, 2, 24},
		{16, 0, 16},
	}
	for value in cases {
		result := pixel_text_size(value.size, value.dpi)
		testing.expect_value(t, result, value.expected)
		dpi := value.dpi if value.dpi > 0 else 1
		device := i32(f32(result) * dpi + 0.5)
		testing.expect_value(t, device % PIXEL_FONT_GRID_PX, i32(0))
	}
}

@(test)
frame_text_size_is_identity_for_mono :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	ui_runtime_set_theme(&runtime, theme_dark())
	frame: Ui_Frame
	ui_frame_begin(&frame, &runtime)
	defer ui_frame_end(&frame)
	for size in ([?]i32{1, 11, 14, 16, 20, 37}) {
		testing.expect_value(t, frame_text_size(&frame, size), size)
	}
	ui_runtime_set_theme(&runtime, theme_pixel())
	testing.expect_value(
		t,
		frame_text_size(&frame, 20),
		pixel_text_size(20, runtime.text.font_dpi),
	)
}

@(test)
font_face_change_bumps_font_epoch :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	backend: Test_Text_Backend_State
	ui_runtime_set_text_backend(
		&runtime,
		{data = &backend, font_for_size = test_text_font_for_size, measure = test_text_measure},
	)
	ui_runtime_set_theme(&runtime, theme_dark())
	epoch := runtime.font_epoch
	ui_runtime_set_theme(&runtime, theme_terra())
	testing.expect_value(t, runtime.font_epoch, epoch)
	ui_runtime_set_theme(&runtime, theme_pixel())
	testing.expect_value(t, runtime.font_epoch, epoch + 1)
	ui_runtime_set_theme(&runtime, theme_dark())
	testing.expect_value(t, runtime.font_epoch, epoch + 2)
}

@(test)
pixel_surfaces_paint_only_rectangles :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	backend: Test_Text_Backend_State
	ui_runtime_set_text_backend(
		&runtime,
		{data = &backend, font_for_size = test_text_font_for_size, measure = test_text_measure},
	)
	ui_runtime_set_theme(&runtime, theme_pixel())
	output := new(Ui_Output)
	defer free(output)
	frame := Ui_Frame {
		output = output,
	}
	ui_frame_begin(&frame, &runtime)
	defer ui_frame_end(&frame)
	for surface in Surface {
		for state in Visual_State {
			output.main.count = 0
			draw_surface(&frame, {10, 10, 120, 40}, surface, state, .MD, .Hairline, .Lifted)
			// Shadow 3 + fill 3 + border 4 + bevel 4.
			testing.expect(t, output.main.count <= 14)
			for index in 0 ..< output.main.count {
				kind := output.main.commands[index].kind
				testing.expect(t, kind == .Rectangle || kind == .Rectangle_Outline)
			}
		}
	}
}

@(test)
dither_stays_inside_its_row_bound :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	ui_runtime_set_theme(&runtime, theme_pixel())
	output := new(Ui_Output)
	defer free(output)
	frame := Ui_Frame {
		output = output,
	}
	for scale in ([?]f32{0.5, 1, 3}) {
		ui_runtime_set_scale(&runtime, scale)
		ui_frame_begin(&frame, &runtime)
		output.main.count = 0
		draw_dither_rect(&frame, {0, 0, 3840, 2160}, runtime.style.modal_dim)
		testing.expect(t, output.main.count > 0)
		testing.expect(t, output.main.count <= DITHER_ROWS_MAX)
		ui_frame_end(&frame)
	}
	testing.expect(t, dither_pitch(1_000_000, 1) >= 2)
}

#+build !js
package ui

import "core:testing"

@(test)
standard_settings_icon_emits_geometry_without_text :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	backend: Test_Text_Backend_State
	test_runtime_init(&runtime, &backend)
	defer ui_runtime_destroy(&runtime)
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

@(test)
every_icon_emits_geometry_at_each_scale :: proc(t: ^testing.T) {
	for scale in ([2]f32{1, 2}) {
		runtime: Ui_Runtime
		ui_runtime_init(&runtime)
		ui_runtime_set_scale(&runtime, scale)
		output := new(Ui_Output)
		frame := Ui_Frame {
			output = output,
		}
		ui_frame_begin(&frame, &runtime)
		for icon in Icon {
			before := output.main.count
			draw_icon_frame(&frame, icon, {4, 4, i32(24 * scale), i32(24 * scale)}, {9, 9, 9, 255})
			testing.expectf(t, output.main.count > before, "%v emits geometry at %v", icon, scale)
			for index in before ..< output.main.count {
				kind := output.main.commands[index].kind
				testing.expect(t, kind != .Text && kind != .Codepoint, "icons never emit text")
			}
		}
		before := output.main.count
		draw_icon_frame(&frame, .Globe, {0, 0, 0, 0}, {9, 9, 9, 255})
		testing.expect_value(t, output.main.count, before)
		ui_frame_end(&frame)
		ui_frame_destroy(&frame)
		free(output)
		ui_runtime_destroy(&runtime)
	}
}

// Icon_Test_Frame owns the runtime and output a pen test draws into, so each
// test reads the commands one primitive emitted without widget chrome. It is
// heap-allocated because the runtime is too large for a test thread's stack.
@(private = "file")
Icon_Test_Frame :: struct {
	runtime: Ui_Runtime,
	output:  ^Ui_Output,
	frame:   Ui_Frame,
}

@(private = "file")
icon_test_begin :: proc(scale: f32) -> ^Icon_Test_Frame {
	fixture := new(Icon_Test_Frame)
	ui_runtime_init(&fixture.runtime)
	ui_runtime_set_scale(&fixture.runtime, scale)
	fixture.output = new(Ui_Output)
	fixture.frame = Ui_Frame {
		output = fixture.output,
	}
	ui_frame_begin(&fixture.frame, &fixture.runtime)
	return fixture
}

@(private = "file")
icon_test_end :: proc(fixture: ^Icon_Test_Frame) {
	ui_frame_end(&fixture.frame)
	ui_frame_destroy(&fixture.frame)
	free(fixture.output)
	ui_runtime_destroy(&fixture.runtime)
	free(fixture)
}

@(private = "file")
icon_test_count :: proc(output: ^Ui_Output, kind: Paint_Kind) -> int {
	count := 0
	for index in 0 ..< output.main.count {
		if output.main.commands[index].kind == kind do count += 1
	}
	return count
}

@(private = "file")
icon_test_near :: proc(a, b: f32) -> bool {
	return abs(a - b) <= 0.001
}

@(private = "file")
icon_test_near_point :: proc(a, b: Vector2) -> bool {
	return icon_test_near(a.x, b.x) && icon_test_near(a.y, b.y)
}

@(test)
icon_pen_line_adds_round_caps :: proc(t: ^testing.T) {
	fixture := icon_test_begin(1)
	defer icon_test_end(fixture)
	pen := icon_pen_make(&fixture.frame, {0, 0, 48, 48}, {9, 9, 9, 255})
	icon_pen_line(&fixture.frame, pen, {6, 6}, {18, 12})
	commands := fixture.output.main.commands[:fixture.output.main.count]
	testing.expect_value(t, len(commands), 3)
	if len(commands) != 3 do return
	testing.expect_value(t, commands[0].kind, Paint_Kind.Line)
	testing.expect(t, icon_test_near(commands[0].thickness, pen.stroke), "line uses pen stroke")
	ends := [2]Vector2{{6, 6}, {18, 12}}
	for end, index in ends {
		cap := commands[index + 1]
		testing.expect_value(t, cap.kind, Paint_Kind.Circle)
		testing.expect(t, icon_test_near(cap.outer_radius, pen.stroke * 0.5), "cap radius")
		testing.expect(t, icon_test_near_point(cap.p0, icon_pen_point(pen, end)), "cap centre")
	}
}

@(test)
icon_pen_polyline_counts_segments_and_joins :: proc(t: ^testing.T) {
	Case :: struct {
		closed, joins:  bool,
		lines, circles: int,
	}
	cases := [3]Case {
		{closed = false, joins = true, lines = 2, circles = 3},
		{closed = true, joins = true, lines = 3, circles = 3},
		{closed = true, joins = false, lines = 3, circles = 0},
	}
	points := [3]Vector2{{4, 4}, {20, 4}, {12, 20}}
	for entry in cases {
		fixture := icon_test_begin(1)
		pen := icon_pen_make(&fixture.frame, {0, 0, 24, 24}, {9, 9, 9, 255})
		icon_pen_polyline(&fixture.frame, pen, points[:], entry.closed, entry.joins)
		testing.expect_value(t, icon_test_count(fixture.output, .Line), entry.lines)
		testing.expect_value(t, icon_test_count(fixture.output, .Circle), entry.circles)
		icon_test_end(fixture)
	}
}

@(test)
icon_pen_arc_caps_open_arcs_only :: proc(t: ^testing.T) {
	fixture := icon_test_begin(1)
	defer icon_test_end(fixture)
	pen := icon_pen_make(&fixture.frame, {0, 0, 48, 48}, {9, 9, 9, 255})
	icon_pen_arc(&fixture.frame, pen, {12, 12}, 8, 90, 270)
	commands := fixture.output.main.commands[:fixture.output.main.count]
	testing.expect_value(t, len(commands), 3)
	if len(commands) != 3 do return
	ring := commands[0]
	radius := 8 * pen.unit
	testing.expect_value(t, ring.kind, Paint_Kind.Ring)
	testing.expect(t, icon_test_near(ring.inner_radius, radius - pen.stroke * 0.5), "inner")
	testing.expect(t, icon_test_near(ring.outer_radius, radius + pen.stroke * 0.5), "outer")
	starts := [2]f32{90, 270}
	for angle, index in starts {
		expected := icon_pen_point(pen, icon_pen_polar({12, 12}, 8, angle))
		testing.expect_value(t, commands[index + 1].kind, Paint_Kind.Circle)
		testing.expect(t, icon_test_near_point(commands[index + 1].p0, expected), "arc cap")
	}
	before := fixture.output.main.count
	icon_pen_circle(&fixture.frame, pen, {12, 12}, 8)
	testing.expect_value(t, fixture.output.main.count - before, 1)
	testing.expect_value(t, fixture.output.main.commands[before].kind, Paint_Kind.Ring)
}

@(test)
icon_pen_rect_rounds_corners :: proc(t: ^testing.T) {
	fixture := icon_test_begin(1)
	defer icon_test_end(fixture)
	pen := icon_pen_make(&fixture.frame, {0, 0, 48, 48}, {9, 9, 9, 255})
	icon_pen_rect(&fixture.frame, pen, 4, 4, 16, 10, 2)
	testing.expect_value(t, icon_test_count(fixture.output, .Line), 4)
	testing.expect_value(t, icon_test_count(fixture.output, .Ring), 4)
	testing.expect_value(t, icon_test_count(fixture.output, .Circle), 0)
	top := fixture.output.main.commands[0]
	testing.expect(t, icon_test_near_point(top.p0, icon_pen_point(pen, {6, 4})), "top edge start")
	testing.expect(t, icon_test_near_point(top.p1, icon_pen_point(pen, {18, 4})), "top edge end")
	before := fixture.output.main.count
	icon_pen_rect(&fixture.frame, pen, 4, 4, 16, 10, 0)
	testing.expect_value(t, fixture.output.main.count - before, 8)
}

@(private = "file")
icon_test_point_inside :: proc(point: Vector2, reach: f32, rect: Rect_I32) -> bool {
	slack: f32 = 0.001
	left := f32(rect.x) - slack
	top := f32(rect.y) - slack
	right := f32(rect.x + rect.w) + slack
	bottom := f32(rect.y + rect.h) + slack
	if point.x - reach < left || point.y - reach < top do return false
	return point.x + reach <= right && point.y + reach <= bottom
}

// icon_test_inside widens each command by its stroke or radius, so the bounds
// check covers painted pixels rather than centrelines.
@(private = "file")
icon_test_inside :: proc(command: Paint_Command, rect: Rect_I32) -> bool {
	#partial switch command.kind {
	case .Line:
		reach := command.thickness * 0.5
		return(
			icon_test_point_inside(command.p0, reach, rect) &&
			icon_test_point_inside(command.p1, reach, rect) \
		)
	case .Circle, .Ring:
		return icon_test_point_inside(command.p0, command.outer_radius, rect)
	}
	return false
}

@(test)
every_icon_is_outline_stroked_within_bounds :: proc(t: ^testing.T) {
	for scale in ([2]f32{1, 2}) {
		for side in ([2]i32{24, 48}) {
			fixture := icon_test_begin(scale)
			rect := Rect_I32{8, 8, i32(f32(side) * scale), i32(f32(side) * scale)}
			for icon in Icon {
				pen := icon_pen_make(&fixture.frame, rect, {9, 9, 9, 255})
				before := fixture.output.main.count
				draw_icon_frame(&fixture.frame, icon, rect, {9, 9, 9, 255})
				emitted := fixture.output.main.count - before
				testing.expectf(t, emitted > 0, "%v emits geometry", icon)
				testing.expectf(t, emitted <= ICON_COMMANDS_MAX, "%v over budget", icon)
				for index in before ..< fixture.output.main.count {
					command := fixture.output.main.commands[index]
					#partial switch command.kind {
					case .Line:
						testing.expectf(
							t,
							icon_test_near(command.thickness, pen.stroke),
							"%v line stroke",
							icon,
						)
					case .Ring:
						width := command.outer_radius - command.inner_radius
						testing.expectf(
							t,
							icon_test_near(width, pen.stroke),
							"%v ring stroke",
							icon,
						)
					case .Circle:
					case:
						testing.expectf(t, false, "%v emits %v", icon, command.kind)
					}
					testing.expectf(
						t,
						icon_test_inside(command, rect),
						"%v paints outside its rect at scale %v side %v",
						icon,
						scale,
						side,
					)
				}
			}
			icon_test_end(fixture)
		}
	}
}

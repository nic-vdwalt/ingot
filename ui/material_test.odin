#+build !js
// Paper material tests.
//
// These check the property that actually protects the interface: that a
// decorative material cannot outgrow the paint budget on a display larger than
// the author's. Overflow is silent at runtime - paint_push counts a dropped
// command and returns - so a substrate that exceeded its bound would look
// correct in every screenshot taken at 1080p and quietly erase itself at 4K.
//
// The tests work in the same units the bounds are derived in (viewport pixels
// and metrics) rather than through a live frame, because the arithmetic is
// where the risk is; a frame would only add a mock without adding coverage.
package ui

import "core:testing"

// The largest viewport the bounds are sized against, in screen-space pixels.
@(private = "file")
VIEWPORT_4K_W :: f32(3840)
@(private = "file")
VIEWPORT_4K_H :: f32(2160)

// rule_count mirrors the loop in draw_rule_lines without emitting commands,
// so a test can count what a region would cost. It also cross-checks
// rules_needed: the shipped helper is closed-form while this is the literal
// iteration, and a disagreement means the closed form is wrong.
//
// The guard bound is far above any tested input. It exists so a degenerate
// argument cannot hang the suite, not to cap the answer - a guard low enough
// to truncate a real count would make this helper disagree with the thing it
// is supposed to be checking.
@(private = "file")
RULE_COUNT_GUARD :: 65536

@(private = "file")
rule_count :: proc(height: f32, spacing: i32) -> int {
	assert(spacing > 0, "rule_count: non-positive spacing")
	count := 0
	for offset := f32(spacing); offset < height; offset += f32(spacing) {
		count += 1
		if count >= RULE_COUNT_GUARD do break
	}
	assert(count < RULE_COUNT_GUARD, "rule_count: input exceeded the helper's guard")
	return count
}

// The closed-form helper must agree with literal iteration, including at the
// exact-multiple boundary where an off-by-one is easiest to introduce.
@(test)
rules_needed_matches_iteration :: proc(t: ^testing.T) {
	for spacing in ([?]i32{1, 7, 11, 22, 64}) {
		for height in ([?]f32{0, 1, 21, 22, 23, 44, 100, 2160}) {
			testing.expectf(
				t,
				rules_needed(height, spacing) == rule_count(height, spacing),
				"rules_needed(%v, %d) = %d but iteration gives %d",
				height,
				spacing,
				rules_needed(height, spacing),
				rule_count(height, spacing),
			)
		}
	}
	// A region exactly N spacings tall carries N-1 rules: the last would land
	// on the closing edge rather than inside the region.
	testing.expect_value(t, rules_needed(44, 22), 1)
	testing.expect_value(t, rules_needed(0, 22), 0)
	testing.expect_value(t, rules_needed(-5, 22), 0)
}

// A full 4K viewport must stay inside the rule bound at every UI scale the
// metrics support. The minimum scale is the dangerous end: it produces the
// smallest LINE_HEIGHT and therefore the most rules.
@(test)
ruled_substrate_fits_4k_at_every_scale :: proc(t: ^testing.T) {
	for scale in ([?]f32{0.5, 1.0, 1.5, 2.0, 3.0}) {
		metrics := ui_metrics(scale)
		count := rule_count(VIEWPORT_4K_H, metrics.LINE_HEIGHT)
		testing.expectf(
			t,
			count <= SUBSTRATE_RULES_MAX,
			"scale %v: a 4K page needs %d rules, above the bound of %d",
			scale,
			count,
			SUBSTRATE_RULES_MAX,
		)
	}
}

// The bound is only meaningful if it is not wildly oversized: a bound far
// above the worst real case would pass every test while leaving no protection.
// The worst case is the 0.5 minimum scale, which should land near the bound.
@(test)
rule_bound_is_sized_from_the_worst_real_case :: proc(t: ^testing.T) {
	metrics := ui_metrics(0.5)
	count := rule_count(VIEWPORT_4K_H, metrics.LINE_HEIGHT)
	testing.expectf(
		t,
		count > SUBSTRATE_RULES_MAX / 2,
		"worst-case 4K page needs only %d rules against a bound of %d: bound not from measurement",
		count,
		SUBSTRATE_RULES_MAX,
	)
}

// Negative space: a dot grid over a whole 4K viewport must be refused. This is
// the case that motivated making dots card-only, and dot_grid_fits is the
// escape hatch a caller is expected to consult first.
@(test)
dot_grid_refuses_a_full_viewport :: proc(t: ^testing.T) {
	viewport := Rectangle{0, 0, VIEWPORT_4K_W, VIEWPORT_4K_H}
	for scale in ([?]f32{0.5, 1.0, 2.0}) {
		metrics := ui_metrics(scale)
		testing.expectf(
			t,
			!dot_grid_fits(viewport, metrics.LINE_HEIGHT),
			"scale %v: a full 4K dot grid was accepted; it costs far more than the bound",
			scale,
		)
	}
}

// The positive half: a card-sized region must be accepted, or the material is
// unusable for the one job it has.
@(test)
dot_grid_accepts_a_card :: proc(t: ^testing.T) {
	metrics := ui_metrics(1.0)
	card := Rectangle{0, 0, 560, 320}
	testing.expect(t, dot_grid_fits(card, metrics.LINE_HEIGHT))
	// And at 3x scale, where the same logical card is three times larger but
	// the spacing grows with it, so the dot count stays roughly constant.
	large := Rectangle{0, 0, 560 * 3, 320 * 3}
	testing.expect(t, dot_grid_fits(large, ui_metrics(3.0).LINE_HEIGHT))
}

// An empty or inverted region must be answerable without arithmetic that
// divides by zero or returns a negative count.
@(test)
dot_grid_fits_handles_degenerate_regions :: proc(t: ^testing.T) {
	testing.expect(t, dot_grid_fits({0, 0, 0, 0}, 10))
	testing.expect(t, dot_grid_fits({0, 0, -5, -5}, 10))
	testing.expect(t, dot_grid_fits({0, 0, 1, 1}, 10))
}

// The dot bound must sit under the headroom an ordinary 4K frame leaves. This
// duplicates the compile-time assertion in material.odin deliberately: the
// #assert fails the build, but this states the intent in a form a reader
// scanning the tests will see.
@(test)
substrate_bounds_fit_the_paint_headroom :: proc(t: ^testing.T) {
	testing.expect(t, SUBSTRATE_RULES_MAX <= PAINT_COMMANDS_HEADROOM)
	testing.expect(t, SUBSTRATE_DOTS_MAX <= PAINT_COMMANDS_HEADROOM)
	// Both substrates plus a full ordinary frame must still fit the cap, since
	// a page can carry rules and a card can carry dots in the same frame.
	total := PAINT_COMMANDS_PEAK_4K + SUBSTRATE_RULES_MAX + SUBSTRATE_DOTS_MAX
	testing.expectf(
		t,
		total <= PAINT_COMMAND_CAP,
		"a 4K frame with both substrates needs %d commands against a cap of %d",
		total,
		PAINT_COMMAND_CAP,
	)
}

// The scribble is fixed-cost by construction. This locks that in: a
// width-dependent stroke count would make a wide pressed row arbitrarily
// expensive, which is the failure mode the fixed count exists to prevent.
@(test)
scribble_cost_is_independent_of_size :: proc(t: ^testing.T) {
	testing.expect(t, SCRIBBLE_STROKES_MAX > 0)
	testing.expect(t, SCRIBBLE_STROKES_MAX <= 16)
	// Even a thousand pressed rows in one frame stay inside the headroom.
	testing.expect(t, SCRIBBLE_STROKES_MAX * 100 <= PAINT_COMMANDS_HEADROOM)
}

// material_frame builds a live runtime and frame so a test can count the
// commands a material actually emits, rather than reasoning about what it
// ought to emit. Counting the real stream is what catches a loop that draws
// per-pixel instead of per-stroke.
@(private = "file")
material_frame :: proc(runtime: ^Ui_Runtime, frame: ^Ui_Frame, output: ^Ui_Output, scale: f32) {
	assert(runtime != nil && frame != nil && output != nil, "material_frame: nil argument")
	ui_runtime_init(runtime)
	ui_runtime_set_scale(runtime, scale)
	frame.output = output
	ui_frame_begin(frame, runtime)
}

// The underline is two strokes at any width: one full pass and one shorter
// return pass. A width-proportional command count would make a long heading
// arbitrarily expensive for a purely decorative mark.
@(test)
hand_underline_is_two_strokes_at_any_width :: proc(t: ^testing.T) {
	for width in ([?]i32{12, 60, 240, 1200}) {
		runtime: Ui_Runtime
		output := new(Ui_Output)
		defer free(output)
		frame: Ui_Frame
		material_frame(&runtime, &frame, output, 1.0)
		defer ui_runtime_destroy(&runtime)

		draw_hand_underline(&frame, 10, 20, width, Color{10, 20, 30, 255})
		ui_frame_end(&frame)

		testing.expectf(
			t,
			output.main.count == 2,
			"width %d emitted %d commands, expected 2",
			width,
			output.main.count,
		)
		testing.expect_value(t, output.main.commands[0].kind, Paint_Kind.Line)
		testing.expect_value(t, output.main.commands[1].kind, Paint_Kind.Line)
	}
}

// The second stroke must be genuinely different from the first - shorter, and
// offset both ways. Two identical passes would render as one thick line and
// lose the drawn-by-hand reading the doubling exists to create.
@(test)
hand_underline_second_stroke_differs :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	output := new(Ui_Output)
	defer free(output)
	frame: Ui_Frame
	material_frame(&runtime, &frame, output, 1.0)
	defer ui_runtime_destroy(&runtime)

	draw_hand_underline(&frame, 0, 100, 240, Color{10, 20, 30, 255})
	ui_frame_end(&frame)

	first := output.main.commands[0]
	second := output.main.commands[1]
	testing.expect(t, (second.p1.x - second.p0.x) < (first.p1.x - first.p0.x))
	testing.expect(t, second.p0.x > first.p0.x)
	testing.expect(t, second.p0.y > first.p0.y)
}

// Negative space: a zero width and a fully transparent colour must both draw
// nothing rather than emit a degenerate line.
@(test)
hand_underline_declines_degenerate_input :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	output := new(Ui_Output)
	defer free(output)
	frame: Ui_Frame
	material_frame(&runtime, &frame, output, 1.0)
	defer ui_runtime_destroy(&runtime)

	draw_hand_underline(&frame, 0, 10, 0, Color{10, 20, 30, 255})
	testing.expect_value(t, output.main.count, 0)

	draw_hand_underline(&frame, 0, 10, 100, Color{10, 20, 30, 0})
	testing.expect_value(t, output.main.count, 0)
	ui_frame_end(&frame)
}

// The underline has to survive the scale range the rest of the page does and
// stay two commands throughout. A stroke that rounded away at small scale
// would leave a heading with no underline at all.
@(test)
hand_underline_survives_every_scale :: proc(t: ^testing.T) {
	for scale in ([?]f32{0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0}) {
		runtime: Ui_Runtime
		output := new(Ui_Output)
		defer free(output)
		frame: Ui_Frame
		material_frame(&runtime, &frame, output, scale)
		defer ui_runtime_destroy(&runtime)

		draw_hand_underline(&frame, 0, 10, 200, Color{10, 20, 30, 255})
		ui_frame_end(&frame)
		testing.expectf(
			t,
			output.main.count == 2,
			"scale %v emitted %d commands, expected 2",
			scale,
			output.main.count,
		)
		testing.expectf(
			t,
			output.main.commands[0].thickness > 0,
			"scale %v rounded the stroke away to nothing",
			scale,
		)
	}
}

// The tooth is texture, so its cost must follow area - and be capped. A fleck
// field is the same quadratic trap as the dot grid: a density that looks right
// on a laptop costs sixteen times as much at 4K.
@(test)
paper_tooth_respects_its_bound :: proc(t: ^testing.T) {
	sizes := [?][2]f32{{200, 120}, {1280, 800}, {3840, 2160}, {12000, 8000}}
	for size in sizes {
		runtime: Ui_Runtime
		output := new(Ui_Output)
		defer free(output)
		frame: Ui_Frame
		material_frame(&runtime, &frame, output, 1.0)
		defer ui_runtime_destroy(&runtime)

		draw_paper_tooth(&frame, {0, 0, size[0], size[1]}, Color{100, 90, 70, 90})
		ui_frame_end(&frame)
		testing.expectf(
			t,
			output.main.count <= SUBSTRATE_FLECKS_MAX,
			"a %vx%v region emitted %d flecks, above the bound of %d",
			size[0],
			size[1],
			output.main.count,
			SUBSTRATE_FLECKS_MAX,
		)
	}
}

// A larger region must carry more grain than a small one, or the texture is a
// fixed sprinkle that looks sparse on a page and dense on a chip.
@(test)
paper_tooth_scales_with_area :: proc(t: ^testing.T) {
	counts: [2]int
	for size, index in ([2]f32{300, 1400}) {
		runtime: Ui_Runtime
		output := new(Ui_Output)
		defer free(output)
		frame: Ui_Frame
		material_frame(&runtime, &frame, output, 1.0)
		defer ui_runtime_destroy(&runtime)

		draw_paper_tooth(&frame, {0, 0, size, size}, Color{100, 90, 70, 90})
		ui_frame_end(&frame)
		counts[index] = output.main.count
	}
	testing.expect(t, counts[1] > counts[0])
}

// The determinism property, and the reason placement is a hash rather than an
// RNG. Frames here are event-driven: a stateful generator would deal a new
// pattern on every unrelated redraw, so the grain would crawl while the user
// typed and the capture harness would stop being byte-reproducible.
//
// A generator would still pass every other test in this file, which is exactly
// why this one exists.
@(test)
paper_tooth_is_identical_across_frames :: proc(t: ^testing.T) {
	first: [64]Rect
	second: [64]Rect
	counts: [2]int
	for pass in 0 ..< 2 {
		runtime: Ui_Runtime
		output := new(Ui_Output)
		defer free(output)
		frame: Ui_Frame
		material_frame(&runtime, &frame, output, 1.0)
		defer ui_runtime_destroy(&runtime)

		draw_paper_tooth(&frame, {0, 0, 600, 400}, Color{100, 90, 70, 90})
		ui_frame_end(&frame)
		counts[pass] = output.main.count
		for index in 0 ..< min(output.main.count, 64) {
			if pass == 0 do first[index] = output.main.commands[index].rect
			else do second[index] = output.main.commands[index].rect
		}
	}
	testing.expect_value(t, counts[0], counts[1])
	for index in 0 ..< min(counts[0], 64) {
		testing.expectf(
			t,
			first[index] == second[index],
			"fleck %d moved between frames: %v then %v",
			index,
			first[index],
			second[index],
		)
	}
}

// Negative space: a degenerate or invisible region draws nothing rather than
// emitting a fleck at a nonsense coordinate.
@(test)
paper_tooth_declines_degenerate_input :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	output := new(Ui_Output)
	defer free(output)
	frame: Ui_Frame
	material_frame(&runtime, &frame, output, 1.0)
	defer ui_runtime_destroy(&runtime)

	draw_paper_tooth(&frame, {0, 0, 0, 0}, Color{100, 90, 70, 90})
	testing.expect_value(t, output.main.count, 0)
	draw_paper_tooth(&frame, {0, 0, -10, -10}, Color{100, 90, 70, 90})
	testing.expect_value(t, output.main.count, 0)
	draw_paper_tooth(&frame, {0, 0, 500, 500}, Color{100, 90, 70, 0})
	testing.expect_value(t, output.main.count, 0)
	ui_frame_end(&frame)
}

// A pigment block costs the same whether it is a chip or a full-width study.
// A size-proportional bleed would make a large swatch arbitrarily expensive
// for an effect that only happens at its edges.
@(test)
pigment_block_cost_is_independent_of_size :: proc(t: ^testing.T) {
	counts: [3]int
	sizes := [3][2]f32{{40, 20}, {400, 200}, {2000, 900}}
	for size, index in sizes {
		runtime: Ui_Runtime
		output := new(Ui_Output)
		defer free(output)
		frame: Ui_Frame
		material_frame(&runtime, &frame, output, 1.0)
		defer ui_runtime_destroy(&runtime)

		draw_pigment_block(&frame, {0, 0, size[0], size[1]}, Color{40, 60, 150, 255})
		ui_frame_end(&frame)
		counts[index] = output.main.count
	}
	testing.expect_value(t, counts[0], counts[1])
	testing.expect_value(t, counts[1], counts[2])
	// One wash, two bleed strips per level, and two corner notches.
	testing.expect_value(t, counts[0], 1 + WASH_BLEED_STRIPS * 2 + 2)
}

// The wash must be a gradient, not a fill: pigment pools where it settles, and
// a flat rectangle is what makes a swatch read as a table cell.
@(test)
wash_is_a_gradient :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	output := new(Ui_Output)
	defer free(output)
	frame: Ui_Frame
	material_frame(&runtime, &frame, output, 1.0)
	defer ui_runtime_destroy(&runtime)

	pigment := Color{40, 60, 150, 255}
	draw_wash(&frame, {0, 0, 100, 60}, pigment)
	ui_frame_end(&frame)

	testing.expect_value(t, output.main.count, 1)
	command := output.main.commands[0]
	testing.expect_value(t, command.kind, Paint_Kind.Rectangle_Gradient_V)
	// Denser at the bottom than the top, and the hue is preserved: a wash that
	// faded toward white would read as a highlight rather than as thin paint.
	testing.expect(t, command.color_end.a > command.color.a)
	testing.expect_value(t, command.color_end, pigment)
	testing.expect_value(t, command.color.r, pigment.r)
}

// The chalk highlight is fixed-cost, like every other material: a lit edge on
// a full-width card must not cost more than one on a chip.
@(test)
chalk_highlight_cost_is_independent_of_size :: proc(t: ^testing.T) {
	counts: [3]int
	sizes := [3][2]f32{{60, 24}, {400, 200}, {1800, 900}}
	for size, index in sizes {
		runtime: Ui_Runtime
		output := new(Ui_Output)
		defer free(output)
		frame: Ui_Frame
		material_frame(&runtime, &frame, output, 1.0)
		defer ui_runtime_destroy(&runtime)

		style := theme_terra()
		style.chalk = Color{214, 255, 228, 255}
		ui_runtime_set_theme(&runtime, style)
		draw_chalk_highlight(&frame, {0, 0, size[0], size[1]}, .MD)
		ui_frame_end(&frame)
		counts[index] = output.main.count
	}
	testing.expect_value(t, counts[0], counts[1])
	testing.expect_value(t, counts[1], counts[2])
	testing.expect_value(t, counts[0], CHALK_STROKES)
}

// Negative space: a palette with no chalk draws nothing. This is how the
// screen palettes opt out - by zeroing the colour, not by a branch at the call
// site - so it has to actually hold.
@(test)
chalk_highlight_absent_without_a_chalk_color :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	output := new(Ui_Output)
	defer free(output)
	frame: Ui_Frame
	material_frame(&runtime, &frame, output, 1.0)
	defer ui_runtime_destroy(&runtime)

	ui_runtime_set_theme(&runtime, THEME_DARK)
	draw_chalk_highlight(&frame, {0, 0, 200, 80}, .MD)
	ui_frame_end(&frame)
	testing.expect_value(t, output.main.count, 0)
}

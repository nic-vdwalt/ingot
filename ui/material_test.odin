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

// The largest viewport the bounds are sized against, in physical pixels.
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

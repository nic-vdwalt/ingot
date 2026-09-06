package main

import shared "../shared"
import "core:testing"

// The brush selector is reachable from three places - the toolbar buttons,
// the bracket keys, and shift+wheel - so the clamp has to live in one
// procedure or the three will disagree about the range.
//
// Client_State is ~183 MB, far past what a test can put on the stack, which
// is why the clamp is a pure proc over an i32 rather than a method on the
// state. The two tests that genuinely need the state heap-allocate it.

@(test)
brush_clamp_bounds_the_selectable_range :: proc(t: ^testing.T) {
	testing.expect_value(
		t,
		terraform_brush_clamp(shared.TERRAFORM_RADIUS_MAX + 5),
		shared.TERRAFORM_RADIUS_MAX,
	)
	testing.expect_value(
		t,
		terraform_brush_clamp(shared.TERRAFORM_RADIUS_MIN - 5),
		shared.TERRAFORM_RADIUS_MIN,
	)
	// Every legal size must be reachable, not merely inside the clamp.
	for radius in shared.TERRAFORM_RADIUS_MIN ..= shared.TERRAFORM_RADIUS_MAX {
		testing.expect_value(t, terraform_brush_clamp(radius), radius)
	}
}

// Stepping past either end must hold, not wrap. A wrap would turn one extra
// keypress at the top of the range into the smallest brush.
@(test)
brush_stepping_saturates_rather_than_wrapping :: proc(t: ^testing.T) {
	radius := shared.TERRAFORM_RADIUS_MAX
	for _ in 0 ..< 4 {
		radius = terraform_brush_clamp(radius + 1)
	}
	testing.expect_value(t, radius, shared.TERRAFORM_RADIUS_MAX)
	radius = shared.TERRAFORM_RADIUS_MIN
	for _ in 0 ..< 4 {
		radius = terraform_brush_clamp(radius - 1)
	}
	testing.expect_value(t, radius, shared.TERRAFORM_RADIUS_MIN)
}

// A clamped radius is fed straight to shared procs that assert their own
// bounds, so the clamp must produce values those procs accept. Reaching
// them without tripping an assertion is the test.
@(test)
brush_radius_is_always_valid_for_the_shared_rules :: proc(t: ^testing.T) {
	for candidate in ([?]i32{min(i32), -100, -1, 0, 2, 4, 5, 100, max(i32)}) {
		radius := terraform_brush_clamp(candidate)
		testing.expect(t, shared.terraform_radius_valid(radius))
		_ = shared.terraform_cell_span(radius)
		_ = shared.terraform_cost_ore(radius)
	}
}

// The brush label is what the toolbar measures and what it draws. If the two
// ever disagreed the panel would resize under the cursor, so the label is a
// pure function of the radius with no state behind it.
@(test)
brush_labels_name_the_odd_spans :: proc(t: ^testing.T) {
	expected := [5]string{"1x1", "3x3", "5x5", "7x7", "9x9"}
	for radius in shared.TERRAFORM_RADIUS_MIN ..= shared.TERRAFORM_RADIUS_MAX {
		testing.expect_value(t, toolbar_brush_label(radius), expected[radius])
	}
}

// The tool-to-direction mapping is what every held command carries into the
// sim; a swapped sign would silently invert raise and lower everywhere.
@(test)
terraform_tool_direction_matches_the_sim_convention :: proc(t: ^testing.T) {
	testing.expect_value(t, terraform_tool_direction(.Raise), i8(1))
	testing.expect_value(t, terraform_tool_direction(.Lower), i8(-1))
	testing.expect_value(t, terraform_tool_direction(.Level), i8(0))
}

// A press seeds exactly one interval, so the first frame of a click must
// drain exactly one step with nothing left over.
@(test)
terraform_hold_first_press_fires_one_step :: proc(t: ^testing.T) {
	steps, remainder := terraform_hold_steps(TERRAFORM_HOLD_INTERVAL)
	testing.expect_value(t, steps, 1)
	testing.expect_value(t, remainder, f32(0))
}

// Accumulated time drains in whole intervals and carries the remainder, so
// the hold cadence is frame-rate independent: two short frames and one long
// frame apply the same number of steps.
@(test)
terraform_hold_steps_drain_whole_intervals :: proc(t: ^testing.T) {
	steps, remainder := terraform_hold_steps(2.5 * TERRAFORM_HOLD_INTERVAL)
	testing.expect_value(t, steps, 2)
	testing.expect(
		t,
		abs(remainder - 0.5 * TERRAFORM_HOLD_INTERVAL) < 0.0001,
		"remainder must carry the fractional interval",
	)
	// Below one interval nothing fires and the accumulator is preserved.
	steps, remainder = terraform_hold_steps(0.5 * TERRAFORM_HOLD_INTERVAL)
	testing.expect_value(t, steps, 0)
	testing.expect_value(t, remainder, f32(0.5 * TERRAFORM_HOLD_INTERVAL))
}

// A negative accumulator (possible only through a future bug upstream) must
// yield zero steps and a non-negative carry, never a sign-flipped command.
@(test)
terraform_hold_steps_tolerate_negative_input :: proc(t: ^testing.T) {
	steps, remainder := terraform_hold_steps(-1)
	testing.expect_value(t, steps, 0)
	testing.expect(t, remainder >= 0, "remainder must not stay negative")
}

// toolbar_rect drives pointer capture: a segment left out of
// toolbar_options_width is a strip of the visible bar whose clicks fall
// through to the world and terraform the ground behind it. The terraform
// row carries the most segments, so it is the one that catches an omission.
//
// The same state also proves the bar does not resize as the player cycles
// brushes - a bar that moved under the cursor would shift the button being
// clicked out from under it - so both properties share one allocation.
@(test)
toolbar_terraform_width_covers_every_segment_and_is_stable :: proc(t: ^testing.T) {
	value := new(Client_State)
	defer free(value)
	value.ui_scale = 1
	value.mode = .Terraform
	value.terraform_radius = shared.TERRAFORM_RADIUS_MIN
	// The note slot has a floor, so a zero measurement still yields a width
	// that accounts for the tools and the brush buttons.
	baseline := toolbar_options_width(value)
	tools := 3 * TOOLBAR_TOOL_WIDTH
	brushes := TOOLBAR_BRUSH_COUNT * TOOLBAR_BRUSH_WIDTH
	testing.expectf(
		t,
		baseline >= tools + brushes + TOOLBAR_NOTE_MIN_WIDTH,
		"terraform options width %d does not cover tools (%d) + brushes (%d) + note floor (%d)",
		baseline,
		tools,
		brushes,
		TOOLBAR_NOTE_MIN_WIDTH,
	)
	for radius in shared.TERRAFORM_RADIUS_MIN ..= shared.TERRAFORM_RADIUS_MAX {
		value.terraform_radius = radius
		testing.expectf(
			t,
			toolbar_options_width(value) == baseline,
			"brush %d changed the toolbar width from %d",
			radius,
			baseline,
		)
	}
}

// The highlight mesh is sized once at compile time and must hold the largest
// brush. A brush wider than the mesh would silently draw a clipped footprint
// - the player would sculpt ground the preview never showed them.
@(test)
highlight_mesh_holds_the_largest_brush :: proc(t: ^testing.T) {
	testing.expect(t, HIGHLIGHT_EXTENT >= shared.TERRAFORM_RADIUS_MAX)
	span := int(2 * HIGHLIGHT_EXTENT + 1)
	testing.expect_value(t, HIGHLIGHT_SPAN, span)
	testing.expect_value(t, HIGHLIGHT_VERTS, span * span * HIGHLIGHT_CELL_VERTS)
	testing.expect_value(t, HIGHLIGHT_INDICES, span * span * HIGHLIGHT_CELL_INDICES)
}

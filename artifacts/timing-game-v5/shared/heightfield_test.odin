package shared

import "core:testing"

_HEIGHTFIELD_TEST_CENTER :: Planet_Coord{.Pos_X, PLANET_FACE_CELLS / 2, PLANET_FACE_CELLS / 2}

// The zero fast path in heightfield_delta_at_coord is only sound while
// `modified` is exact. A false negative silently drops every terraform edit
// from the client's height cache and material bake, so these pin the
// transitions.
@(test)
heightfield_starts_unmodified_and_samples_zero :: proc(t: ^testing.T) {
	field: Heightfield
	heightfield_init(&field)
	defer heightfield_deinit(&field)
	testing.expect(t, !field.modified, "fresh heightfield is unmodified")
	testing.expect_value(t, heightfield_delta_at_coord(&field, _HEIGHTFIELD_TEST_CENTER), f32(0))
}

@(test)
heightfield_apply_sets_modified_and_delta_is_visible :: proc(t: ^testing.T) {
	field: Heightfield
	heightfield_init(&field)
	defer heightfield_deinit(&field)
	planet_heightfield_apply(&field, _HEIGHTFIELD_TEST_CENTER, 1)
	testing.expect(t, field.modified, "apply marks the field modified")
	// Without the flag being set, this would read back as zero.
	testing.expect(
		t,
		heightfield_delta_at_coord(&field, _HEIGHTFIELD_TEST_CENTER) > 0,
		"raised centre is visible",
	)
}

// A write of an explicit zero must not set the flag: that is the flatten case
// on already-flat ground and keeps pristine worlds on the fast path.
@(test)
heightfield_set_delta_zero_leaves_field_unmodified :: proc(t: ^testing.T) {
	field: Heightfield
	heightfield_init(&field)
	defer heightfield_deinit(&field)
	heightfield_set_delta(&field, 0, 0)
	testing.expect(t, !field.modified, "writing zero leaves the field unmodified")
	heightfield_set_delta(&field, 0, TERRAFORM_STEP)
	testing.expect(t, field.modified, "writing non-zero marks the field modified")
}

@(test)
heightfield_recount_modified_matches_contents :: proc(t: ^testing.T) {
	field: Heightfield
	heightfield_init(&field)
	defer heightfield_deinit(&field)
	field.modified = true
	heightfield_recount_modified(&field)
	testing.expect(t, !field.modified, "recount clears the flag on an all-zero grid")
	field.deltas[len(field.deltas) - 1] = TERRAFORM_STEP
	heightfield_recount_modified(&field)
	testing.expect(t, field.modified, "recount finds a non-zero delta")
}

// A terraformed world must survive the snapshot round trip with the derived
// flag rebuilt, otherwise a restored world renders its terrain flat.
@(test)
heightfield_modified_survives_snapshot_roundtrip :: proc(t: ^testing.T) {
	source := new(World)
	defer free(source)
	testing.expect(t, world_init_seed(source, TERRAIN_SEED), "source world init")
	defer world_deinit(source)
	planet_heightfield_apply(&source.heightfield, _HEIGHTFIELD_TEST_CENTER, 1)
	testing.expect(t, source.heightfield.modified, "source is modified")
	buffer := make([]u8, world_snapshot_size(source))
	defer delete(buffer)
	written, ok := world_snapshot_write(source, buffer)
	testing.expect(t, ok && written == len(buffer), "snapshot write")

	target := new(World)
	defer free(target)
	testing.expect(t, world_init_seed(target, TERRAIN_SEED), "target world init")
	defer world_deinit(target)
	testing.expect(t, !target.heightfield.modified, "target starts unmodified")
	testing.expect(t, world_snapshot_read(target, buffer), "snapshot read")
	testing.expect(t, target.heightfield.modified, "restored world is modified")
	testing.expect_value(
		t,
		planet_heightfield_delta(&target.heightfield, _HEIGHTFIELD_TEST_CENTER),
		planet_heightfield_delta(&source.heightfield, _HEIGHTFIELD_TEST_CENTER),
	)
}

// The default brush must be bit-identical to the single-size implementation
// this replaced, or every existing determinism and cost assertion silently
// changed meaning. 6/4/2 are the original ring steps.
@(test)
terraform_default_brush_reproduces_the_original_rings :: proc(t: ^testing.T) {
	field: Heightfield
	heightfield_init(&field)
	defer heightfield_deinit(&field)
	center := _HEIGHTFIELD_TEST_CENTER
	planet_heightfield_apply(&field, center, 1, TERRAFORM_RADIUS)
	expected := [3]i16{6, 4, 2}
	for ring in 0 ..< i32(3) {
		coord := Planet_Coord{center.face, center.u + ring, center.v}
		delta := field.deltas[planet_index(coord)]
		testing.expectf(
			t,
			delta == expected[ring],
			"ring %d is %d, expected %d",
			ring,
			delta,
			expected[ring],
		)
	}
}

// Every brush size lifts its centre by the same amount. Without this, a
// 9x9 brush would raise a peak five times taller than a 1x1 from one click,
// which makes the large brush a different tool rather than a wider one.
@(test)
terraform_peak_is_independent_of_brush_size :: proc(t: ^testing.T) {
	center := _HEIGHTFIELD_TEST_CENTER
	for radius in TERRAFORM_RADIUS_MIN ..= TERRAFORM_RADIUS_MAX {
		field: Heightfield
		heightfield_init(&field)
		defer heightfield_deinit(&field)
		planet_heightfield_apply(&field, center, 1, radius)
		delta := field.deltas[planet_index(center)]
		testing.expectf(
			t,
			delta == TERRAFORM_PEAK,
			"radius %d lifted the centre by %d, expected the constant peak %d",
			radius,
			delta,
			TERRAFORM_PEAK,
		)
	}
}

// The mound must fall away monotonically from the centre and reach zero
// outside the brush, which is what makes the brush size the player selects
// the size they actually get.
@(test)
terraform_mound_falls_off_and_stops_at_the_brush_edge :: proc(t: ^testing.T) {
	center := _HEIGHTFIELD_TEST_CENTER
	for radius in TERRAFORM_RADIUS_MIN ..= TERRAFORM_RADIUS_MAX {
		field: Heightfield
		heightfield_init(&field)
		defer heightfield_deinit(&field)
		planet_heightfield_apply(&field, center, 1, radius)
		previous := i16(max(i16))
		for ring in i32(0) ..= radius {
			coord := Planet_Coord{center.face, center.u + ring, center.v}
			delta := field.deltas[planet_index(coord)]
			testing.expectf(
				t,
				delta > 0,
				"radius %d ring %d moved no ground",
				radius,
				ring,
			)
			testing.expectf(
				t,
				delta < previous,
				"radius %d ring %d did not fall away from ring %d",
				radius,
				ring,
				ring - 1,
			)
			previous = delta
		}
		outside := Planet_Coord{center.face, center.u + radius + 1, center.v}
		testing.expectf(
			t,
			field.deltas[planet_index(outside)] == 0,
			"radius %d moved ground one cell beyond its own edge",
			radius,
		)
	}
}

// An edit landing on a face edge must reach the duplicate cell the adjacent
// face stores for the same sphere point; a one-sided write reads back as a
// crack at the seam.
@(test)
heightfield_edge_writes_mirror_to_adjacent_faces :: proc(t: ^testing.T) {
	field: Heightfield
	heightfield_init(&field)
	defer heightfield_deinit(&field)
	edge := Planet_Coord{.Pos_X, PLANET_FACE_CELLS, PLANET_FACE_CELLS / 2}
	planet_heightfield_apply(&field, edge, 1, 0)
	duplicates, count := planet_duplicates(edge)
	testing.expect(t, count >= 1, "an edge cell has at least one duplicate")
	canonical := planet_canonical(edge)
	expected := field.deltas[planet_index(canonical)]
	testing.expect(t, expected != 0, "the canonical cell carries the edit")
	testing.expect_value(t, field.deltas[planet_index(edge)], expected)
	for index in 0 ..< count {
		testing.expect_value(t, field.deltas[planet_index(duplicates[index])], expected)
	}
}

// Cost scales with area and is exact at the default. The default equality
// is what keeps the cost assertions in sim_test.odin meaningful.
@(test)
terraform_cost_scales_with_brush_area :: proc(t: ^testing.T) {
	testing.expect_value(t, terraform_cost_ore(TERRAFORM_RADIUS), TERRAFORM_COST_ORE)
	expected := [5]u64{1, 2, 5, 10, 17}
	for radius in TERRAFORM_RADIUS_MIN ..= TERRAFORM_RADIUS_MAX {
		testing.expect_value(t, terraform_cost_ore(radius), expected[radius])
	}
	previous := u64(0)
	for radius in TERRAFORM_RADIUS_MIN ..= TERRAFORM_RADIUS_MAX {
		cost := terraform_cost_ore(radius)
		testing.expectf(t, cost > previous, "radius %d is not dearer than radius %d", radius, radius - 1)
		previous = cost
	}
}

// The selectable sizes are the odd spans 1x1 through 9x9 and nothing else.
// An out-of-range radius must be refused by the shared rule rather than
// asserted on, because it can arrive from a command.
@(test)
terraform_radius_bounds_admit_only_the_odd_spans :: proc(t: ^testing.T) {
	testing.expect(t, !terraform_radius_valid(TERRAFORM_RADIUS_MIN - 1))
	testing.expect(t, !terraform_radius_valid(TERRAFORM_RADIUS_MAX + 1))
	expected := [5]i32{1, 3, 5, 7, 9}
	for radius in TERRAFORM_RADIUS_MIN ..= TERRAFORM_RADIUS_MAX {
		testing.expect(t, terraform_radius_valid(radius))
		testing.expect_value(t, terraform_cell_span(radius), expected[radius])
	}
}

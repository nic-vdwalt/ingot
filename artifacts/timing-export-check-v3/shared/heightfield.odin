package shared

// Mutable terrain state for terraforming. The analytic procgen heightfield is
// the immutable base; this delta grid is the only mutable layer, stored in
// quarter-unit fixed point so every tick result is bit-identical across
// platforms. The authoritative grid remains spaced at GRID_CELL_SIZE while
// finer client render vertices bilinearly sample this same delta surface.

HEIGHTFIELD_RESOLUTION :: WORLD_CHUNKS * 32 + 1
HEIGHT_DELTA_SCALE :: i16(4)

// One terraform apply moves a linear-falloff mound whose peak is
// TERRAFORM_PEAK fixed-point units regardless of brush size. TERRAFORM_STEP
// is the ring quantum the default brush was authored around and is what
// makes TERRAFORM_PEAK a derived value rather than a new magic number.
TERRAFORM_STEP :: i16(2)
TERRAFORM_MAX_DELTA :: i16(48)
// The default brush: a 5x5 mound, the size every existing test and the
// original single-size implementation assume.
TERRAFORM_RADIUS :: i32(2)
// Selectable brush sizes are 1x1 through 9x9. Only odd sizes exist because
// the mound is anchored on a heightfield *vertex*: an even brush has no
// centre vertex to fall away from, and giving it one would mean shifting
// the footprint half a cell off the tile the player is pointing at.
TERRAFORM_RADIUS_MIN :: i32(0)
TERRAFORM_RADIUS_MAX :: i32(4)
// Peak displacement at the mound centre, in fixed-point units. Held
// constant across brush sizes: a 9x9 brush should move more ground than a
// 1x1, not build a mountain five times taller from the same single click.
TERRAFORM_PEAK :: i16(TERRAFORM_STEP * i16(TERRAFORM_RADIUS + 1))
// Ore charged for one apply at the default brush. terraform_cost_ore
// scales this by area, and is exact at the default by construction.
TERRAFORM_COST_ORE :: u64(5)

// terraform_radius_valid is the single bounds rule for a brush size, shared
// by command validation and by the client's brush selector so the two can
// never disagree about which sizes exist.
terraform_radius_valid :: proc(radius: i32) -> bool {
	return radius >= TERRAFORM_RADIUS_MIN && radius <= TERRAFORM_RADIUS_MAX
}

// terraform_cell_span is the brush's edge length in cells: 1, 3, 5, 7, 9.
terraform_cell_span :: proc(radius: i32) -> i32 {
	assert(terraform_radius_valid(radius), "terraform_cell_span: radius out of range")
	return 2 * radius + 1
}

// terraform_cost_ore scales the default cost by the brush's area, rounding
// up so the smallest brush still costs something. Integer-only and pure:
// this runs inside command validation, which must stay deterministic.
//
//	r=0 -> 1    r=1 -> 2    r=2 -> 5    r=3 -> 10    r=4 -> 17
//
// The default radius reproduces TERRAFORM_COST_ORE exactly, which is what
// keeps every existing cost assertion meaningful.
terraform_cost_ore :: proc(radius: i32) -> u64 {
	assert(terraform_radius_valid(radius), "terraform_cost_ore: radius out of range")
	span := u64(terraform_cell_span(radius))
	default_span := u64(terraform_cell_span(TERRAFORM_RADIUS))
	default_cells := default_span * default_span
	numerator := TERRAFORM_COST_ORE * span * span
	// Ceiling division: a brush that moves any ground at all has a cost.
	cost := (numerator + default_cells - 1) / default_cells
	assert(cost > 0, "terraform_cost_ore: free terraform")
	return cost
}

Heightfield :: Planet_Heightfield

// heightfield_set_delta is the single write path into the delta grid, so the
// derived `modified` flag cannot go stale. Writing the deltas slice directly
// would silently defeat the zero fast path below.
heightfield_set_delta :: proc(field: ^Heightfield, index: int, delta: i16) {
	assert(field != nil, "heightfield_set_delta: nil field")
	assert(index >= 0 && index < len(field.deltas), "heightfield_set_delta: index out of range")
	assert(
		delta >= -TERRAFORM_MAX_DELTA && delta <= TERRAFORM_MAX_DELTA,
		"heightfield_set_delta: delta out of range",
	)
	field.deltas[index] = delta
	if delta != 0 do field.modified = true
}

// heightfield_recount_modified rebuilds the derived flag from the delta grid;
// used after a snapshot restore, which writes the deltas wholesale.
heightfield_recount_modified :: proc(field: ^Heightfield) {
	assert(field != nil, "heightfield_recount_modified: nil field")
	field.modified = false
	for delta in field.deltas {
		if delta != 0 {
			field.modified = true
			return
		}
	}
}

heightfield_init :: proc(field: ^Heightfield, allocator := context.allocator) {
	assert(field != nil, "heightfield_init: nil field")
	field^ = {}
	field.deltas = make([]i16, PLANET_FIELD_CELLS, allocator)
}

heightfield_deinit :: proc(field: ^Heightfield, allocator := context.allocator) {
	assert(field != nil, "heightfield_deinit: nil field")
	delete(field.deltas, allocator)
	field^ = {}
}

// heightfield_delta_at_coord returns the accumulated delta at a cell in
// world units. An untouched world short-circuits through the modified flag.
heightfield_delta_at_coord :: proc(field: ^Heightfield, coord: Planet_Coord) -> f32 {
	assert(field != nil, "heightfield_delta_at_coord: nil field")
	if !field.modified do return 0
	if !planet_coord_valid(coord) do return 0
	return f32(field.deltas[planet_index(coord)]) / f32(HEIGHT_DELTA_SCALE)
}

// height_to_fixed quantises a world-unit height to quarter-unit fixed point,
// rounding to nearest so flatten targets are stable across platforms. The
// clamp keeps the intermediate well inside i16 range.
height_to_fixed :: proc(height: f32) -> i16 {
	scaled := height * f32(HEIGHT_DELTA_SCALE)
	scaled = clamp(scaled, -16000, 16000)
	if scaled >= 0 do return i16(scaled + 0.5)
	return -i16(-scaled + 0.5)
}

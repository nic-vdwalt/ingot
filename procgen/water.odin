package procgen

Water_Step_Result :: struct {
	moved:  bool,
	volume: u64,
}

water_initialize :: proc(ground: []i32, depth: []u32, level: i32) -> u64 {
	assert(len(ground) == len(depth), "water_initialize: size mismatch")
	assert(len(depth) > 0, "water_initialize: empty field")
	volume: u64
	for height, index in ground {
		amount: u32
		if height < level {
			difference := i64(level) - i64(height)
			assert(difference <= i64(max(u32)), "water_initialize: depth overflow")
			amount = u32(difference)
		}
		depth[index] = amount
		assert(volume <= max(u64) - u64(amount), "water_initialize: volume overflow")
		volume += u64(amount)
	}
	return volume
}

water_total :: proc(depth: []u32) -> u64 {
	volume: u64
	for amount in depth {
		assert(volume <= max(u64) - u64(amount), "water_total: volume overflow")
		volume += u64(amount)
	}
	return volume
}

water_surface :: proc(ground: []i32, depth: []u32, index: int) -> i64 {
	assert(len(ground) == len(depth), "water_surface: size mismatch")
	assert(index >= 0 && index < len(depth), "water_surface: index out of bounds")
	return i64(ground[index]) + i64(depth[index])
}

water_step :: proc(
	ground: []i32,
	depth: []u32,
	width, height: int,
	max_transfer: u32,
	phase: u32,
) -> Water_Step_Result {
	assert(width > 1 && height > 1, "water_step: degenerate dimensions")
	assert(width <= max(int) / height, "water_step: dimension overflow")
	assert(len(ground) == width * height, "water_step: ground size mismatch")
	assert(len(depth) == len(ground), "water_step: depth size mismatch")
	assert(max_transfer > 0, "water_step: zero transfer cap")
	before := water_total(depth)
	moved := false
	first := int(phase & 1)
	for pass in 0 ..< 2 {
		parity := (first + pass) & 1
		for row in 0 ..< height {
			for column := parity; column < width - 1; column += 2 {
				left := row * width + column
				if _water_transfer_pair(ground, depth, left, left + 1, max_transfer) {
					moved = true
				}
			}
		}
	}
	first = int((phase >> 1) & 1)
	for pass in 0 ..< 2 {
		parity := (first + pass) & 1
		for row := parity; row < height - 1; row += 2 {
			for column in 0 ..< width {
				top := row * width + column
				if _water_transfer_pair(ground, depth, top, top + width, max_transfer) {
					moved = true
				}
			}
		}
	}
	after := water_total(depth)
	assert(after == before, "water_step: volume changed")
	return {moved, after}
}

@(private)
_water_transfer_pair :: proc(
	ground: []i32,
	depth: []u32,
	first, second: int,
	max_transfer: u32,
) -> bool {
	assert(first >= 0 && first < len(depth), "_water_transfer_pair: first out of bounds")
	assert(second >= 0 && second < len(depth), "_water_transfer_pair: second out of bounds")
	first_surface := i64(ground[first]) + i64(depth[first])
	second_surface := i64(ground[second]) + i64(depth[second])
	if first_surface == second_surface do return false
	source, target := first, second
	difference := first_surface - second_surface
	if difference < 0 {
		source, target = second, first
		difference = -difference
	}
	amount := min(u64(difference / 2), u64(max_transfer), u64(depth[source]))
	if amount == 0 do return false
	assert(u64(depth[target]) + amount <= u64(max(u32)), "_water_transfer_pair: depth overflow")
	depth[source] -= u32(amount)
	depth[target] += u32(amount)
	return true
}

package shared

import "core:math/rand"
import "core:testing"

// The Newton iteration integer_sqrt replaced: kept as the oracle.
@(private = "file")
integer_sqrt_reference :: proc(value: u64) -> u64 {
	if value == 0 do return 0
	x := value
	next := (x + 1) / 2
	for next < x {
		x = next
		next = (x + value / x) / 2
	}
	return x
}

@(test)
integer_sqrt_matches_newton_reference :: proc(t: ^testing.T) {
	edges := [?]u64 {
		0, 1, 2, 3, 4, 5, 8, 9, 15, 16, 17, 24, 25, 26, 99, 100, 101,
		0xFFFF_FFFF, 0x1_0000_0000, 0x1_0000_0001,
		(1 << 32 - 1) * (1 << 32 - 1) - 1, (1 << 32 - 1) * (1 << 32 - 1), (1 << 32 - 1) * (1 << 32 - 1) + 1,
		1 << 53 - 1, 1 << 53, 1 << 53 + 1, 1 << 63 - 1, 1 << 63, 1 << 63 + 1, max(u64) - 1,
	}
	for value in edges do testing.expect_value(t, integer_sqrt(value), integer_sqrt_reference(value))
	// The Newton form overflows on max(u64) itself; the exact answer is known.
	testing.expect_value(t, integer_sqrt(max(u64)), u64(0xFFFF_FFFF))
	// Perfect squares and their neighbours across the whole magnitude range.
	for bits in 0 ..< 32 {
		root := u64(1) << u32(bits)
		for delta in u64(0) ..= 3 {
			square := (root + delta) * (root + delta)
			testing.expect_value(t, integer_sqrt(square), root + delta)
			testing.expect_value(t, integer_sqrt(square - 1), root + delta - 1)
			testing.expect_value(t, integer_sqrt(square + 1), root + delta)
		}
	}
	state := rand.create(0x5eed_c0de)
	generator := rand.default_random_generator(&state)
	for _ in 0 ..< 200_000 {
		value := rand.uint64(generator) >> u64(rand.int_max(64, generator))
		testing.expect_value(t, integer_sqrt(value), integer_sqrt_reference(value))
	}
}

// The derived wave fields are cached by bathymetry revision and per-cell
// period; every wave step must still produce what an uncached derivation
// produces, including across a bathymetry change and a snapshot restore.
@(test)
wave_derived_cache_matches_uncached_derivation :: proc(t: ^testing.T) {
	cached := new(World)
	uncached := new(World)
	defer free(cached)
	defer free(uncached)
	testing.expect(t, world_init_seed(cached, TERRAIN_SEED))
	defer world_deinit(cached)
	testing.expect(t, world_init_seed(uncached, TERRAIN_SEED))
	defer world_deinit(uncached)
	expect_equal :: proc(t: ^testing.T, first, second: ^Wave_State) {
		for value, index in first.phase_speed_mm_s do testing.expect_value(t, value, second.phase_speed_mm_s[index])
		for value, index in first.group_speed_mm_s do testing.expect_value(t, value, second.group_speed_mm_s[index])
		for value, index in first.shoal_gain do testing.expect_value(t, value, second.shoal_gain[index])
		for value, index in first.depth_gradient_east do testing.expect_value(t, value, second.depth_gradient_east[index])
		for value, index in first.depth_gradient_north do testing.expect_value(t, value, second.depth_gradient_north[index])
		for value, index in first.height_mm do testing.expect_value(t, value, second.height_mm[index])
		for value, index in first.breaking do testing.expect_value(t, value, second.breaking[index])
		for value, index in first.runup_mm do testing.expect_value(t, value, second.runup_mm[index])
	}
	for tick in u64(0) ..< 40 {
		world_planetary_step(cached, tick)
		waves_invalidate_derived(&uncached.planetary.waves)
		world_planetary_step(uncached, tick)
		if tick == 16 {
			// A terraform-sized bathymetry edit through the ocean sync path
			// must bump the revision and refresh the gradients.
			for world in ([]^World{cached, uncached}) {
				for index in 0 ..< 512 do world.planetary.ocean.mean_depth_mm[index] += 1_000
				world.planetary.ocean.bathymetry_revision += 1
			}
		}
		if tick == 24 {
			size := planetary_snapshot_size(&cached.planetary)
			buffer := make([]u8, size)
			defer delete(buffer)
			written, ok_write := planetary_snapshot_write(&cached.planetary, buffer)
			testing.expect(t, ok_write && written == size, "snapshot write")
			testing.expect(t, planetary_snapshot_read(&cached.planetary, buffer))
			testing.expect_value(t, cached.planetary.waves.bathymetry_revision, u64(0))
		}
	}
	expect_equal(t, &cached.planetary.waves, &uncached.planetary.waves)
	hits := 0
	for period in cached.planetary.waves.dispersion_period_ms do if period != 0 do hits += 1
	testing.expect_value(t, hits, PLANET_SIM_CELL_COUNT)
}

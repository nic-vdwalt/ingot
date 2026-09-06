package shared

// Swell ring rasterisation benchmark. One wave step rasterises every active
// ring into the annulus of cells under its band, so the per-step cost scales
// with the ring count rather than the packet count of the old spoke model.
//
//   bash build.sh bench
//
// Gated behind FORGE_BENCH like the other load-time benchmarks.

import "core:testing"

@(test)
bench_waves_harness_reports_state :: proc(t: ^testing.T) {
	testing.expect_value(t, WAVE_SWELL_PACKET_MAX, 128)
	testing.expect_value(t, WAVE_RING_SECTOR_COUNT, 64)
}

when BENCH_ENABLED {
	@(private = "file")
	bench_wave_planet: ^Planetary_State

	// 128 rings spread between a quarter and three quarters of the way to
	// the antipode over a uniform deep ocean: the widest annuli the model
	// can produce, all at once.
	@(test)
	bench_waves_ring_rasterize :: proc(t: ^testing.T) {
		planet := new(Planetary_State)
		defer free(planet)
		planet.physical = planet_physical_earthlike()
		planet_sim_grid_init(&planet.grid, planet.physical)
		defer planet_sim_grid_deinit(&planet.grid)
		planet.ocean.mean_depth_mm = make([]u32, PLANET_SIM_CELL_COUNT)
		defer delete(planet.ocean.mean_depth_mm)
		waves_init(&planet.waves)
		defer waves_deinit(&planet.waves)
		for index in 0 ..< PLANET_SIM_CELL_COUNT do planet.ocean.mean_depth_mm[index] = 500_000
		waves_derive_bathymetry(planet)
		circumference := planet.physical.radius_m * 1_000 * 3_142 / 1_000
		for &packet, index in planet.waves.packets {
			source := u32((index * 431) % PLANET_SIM_CELL_COUNT)
			packet = {
				active           = true,
				id               = u32(index + 1),
				source_id        = u32(index + 1),
				source_cell      = source,
				period_ms        = 9_625,
				action           = 4_000_000,
				radius_mm        = circumference /
					4 + circumference / 2 * u64(index) / WAVE_SWELL_PACKET_MAX,
				band_mm          = wave_ring_band_mm(planet, source, 9_625),
				group_speed_mm_s = 7_500,
			}
		}
		planet.waves.packet_count = WAVE_SWELL_PACKET_MAX
		bench_wave_planet = planet
		_bench("waves ring rasterize x128", proc() {
			waves_rasterize_packets(bench_wave_planet)
		})
		_bench("waves ring advance x128", proc() {
			for &packet in bench_wave_planet.waves.packets {
				if packet.active do wave_packet_advance(bench_wave_planet, &packet, 600)
			}
		})
		wet := 0
		for variance in planet.waves.swell_variance do if variance > 0 do wet += 1
		testing.expect(t, wet > 0, "bench_waves_ring_rasterize: no output")
	}
}

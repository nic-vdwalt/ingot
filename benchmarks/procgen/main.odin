package main

import "core:fmt"
import "core:time"
import procgen "ingot:procgen"

BENCHMARK_EDGE :: 129
BENCHMARK_SAMPLES :: BENCHMARK_EDGE * BENCHMARK_EDGE
BENCHMARK_HALO :: (BENCHMARK_EDGE + 2) * (BENCHMARK_EDGE + 2)
BENCHMARK_ITERATIONS :: 20

Storage :: struct {
	height_halo:     [BENCHMARK_HALO]f32,
	heights:         [BENCHMARK_SAMPLES]f32,
	moisture:        [BENCHMARK_SAMPLES]f32,
	temperature:     [BENCHMARK_SAMPLES]f32,
	continentalness: [BENCHMARK_SAMPLES]f32,
	ruggedness:      [BENCHMARK_SAMPLES]f32,
	derivative_x:    [BENCHMARK_SAMPLES]f32,
	derivative_y:    [BENCHMARK_SAMPLES]f32,
	slope:           [BENCHMARK_SAMPLES]f32,
	biomes:          [BENCHMARK_SAMPLES]procgen.Terrain_Biome_Blend_V2,
}

main :: proc() {
	storage: Storage
	recipe := procgen.terrain_default_recipe_v2(0x7E44AF0463)
	request := procgen.Terrain_Field_Request_V2{-128, -128, 2, BENCHMARK_EDGE, BENCHMARK_EDGE}
	buffer := procgen.Terrain_Field_Buffer_V2 {
		height_halo     = storage.height_halo[:],
		heights         = storage.heights[:],
		moisture        = storage.moisture[:],
		temperature     = storage.temperature[:],
		continentalness = storage.continentalness[:],
		ruggedness      = storage.ruggedness[:],
		derivative_x    = storage.derivative_x[:],
		derivative_y    = storage.derivative_y[:],
		slope           = storage.slope[:],
		biomes          = storage.biomes[:],
	}
	start := time.now()
	for _ in 0 ..< BENCHMARK_ITERATIONS {
		assert(procgen.terrain_generate_field_v2(&recipe, request, buffer))
	}
	elapsed := time.since(start)
	fmt.printf(
		"v2 field %dx%d: %v total, %v/field\n",
		BENCHMARK_EDGE,
		BENCHMARK_EDGE,
		elapsed,
		elapsed / BENCHMARK_ITERATIONS,
	)
	benchmark_v3_density(.Normal)
	benchmark_v3_density(.Abstract)
}

benchmark_v3_density :: proc(preset: procgen.Terrain_Preset_V3) {
	recipe := procgen.terrain_normal_recipe_v3(0x7E44AF0463)
	if preset == .Abstract do recipe = procgen.terrain_abstract_recipe_v3(0x7E44AF0463)
	// Validate once. Measuring `terrain_density_v3` here would time the recipe
	// walk -- 31 floats, 16 biome profiles, 5 noise configs -- once per sample,
	// which is not what a field bake pays.
	assert(procgen.terrain_recipe_validate_v3(&recipe), "benchmark_v3_density: invalid recipe")
	start := time.now()
	checksum := f32(0)
	for _ in 0 ..< BENCHMARK_ITERATIONS {
		for z in 0 ..< 16 {
			for y in 0 ..< 32 {
				for x in 0 ..< 32 {
					value, ok := procgen.terrain_density_prevalidated_v3(
						&recipe,
						f32(x * 4),
						f32(y * 4),
						f32(z * 4 - 32),
					)
					assert(ok)
					checksum += value
				}
			}
		}
	}
	elapsed := time.since(start)
	fmt.printf("v3 %v density: %v total, checksum %.2f\n", preset, elapsed, checksum)
}

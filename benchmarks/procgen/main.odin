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
		height_halo = storage.height_halo[:],
		heights = storage.heights[:],
		moisture = storage.moisture[:],
		temperature = storage.temperature[:],
		continentalness = storage.continentalness[:],
		ruggedness = storage.ruggedness[:],
		derivative_x = storage.derivative_x[:],
		derivative_y = storage.derivative_y[:],
		slope = storage.slope[:],
		biomes = storage.biomes[:],
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
}

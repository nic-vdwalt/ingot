package fuzz_procgen

import "core:fmt"
import "ingot:asset"
import fuzzx "ingot:fuzz/fuzzx"
import "ingot:procgen"

ITERATIONS_DEFAULT :: 10_000

FUZZ_VOLUME_CELLS :: 4
FUZZ_VOLUME_DENSITY :: (FUZZ_VOLUME_CELLS + 2) * (FUZZ_VOLUME_CELLS + 2) * (FUZZ_VOLUME_CELLS + 2)
FUZZ_VOLUME_VERTICES :: FUZZ_VOLUME_CELLS * FUZZ_VOLUME_CELLS * FUZZ_VOLUME_CELLS * 24
FUZZ_VOLUME_INDICES :: FUZZ_VOLUME_CELLS * FUZZ_VOLUME_CELLS * FUZZ_VOLUME_CELLS * 36

Storage :: struct {
	vertices:        [procgen.TERRAIN_CHUNK_VERTICES]asset.Vertex,
	indices:         [procgen.TERRAIN_CHUNK_INDICES]u32,
	volume_density:  [FUZZ_VOLUME_DENSITY]f32,
	volume_vertices: [FUZZ_VOLUME_VERTICES]asset.Vertex,
	volume_indices:  [FUZZ_VOLUME_INDICES]u32,
}

main :: proc() {
	seed, iterations, rounds := fuzzx.parse_options(ITERATIONS_DEFAULT)
	fmt.printfln("fuzz_procgen seed=%d iterations=%d rounds=%d", seed, iterations, rounds)
	for round in 0 ..< rounds {
		round_seed := seed + u64(round)
		prng := fuzzx.prng_make(round_seed)
		ctx := fuzzx.Ctx {
			name = "fuzz_procgen",
			seed = round_seed,
		}
		for iteration in 0 ..< iterations {
			ctx.iteration = iteration
			exercise_chunk(&ctx, &prng)
			exercise_volume(&ctx, &prng)
		}
	}
}

exercise_chunk :: proc(ctx: ^fuzzx.Ctx, prng: ^fuzzx.Prng) {
	assert(ctx != nil, "exercise_chunk: nil context")
	assert(prng != nil, "exercise_chunk: nil prng")
	storage: Storage
	chunk := procgen.Terrain_Chunk {
		mesh = {
			id = 1,
			vertices = storage.vertices[:],
			indices = storage.indices[:],
			primitive = .Triangles,
		},
		chunk_x = i32(fuzzx.int_range(prng, -1024, 1024)),
		chunk_y = i32(fuzzx.int_range(prng, -1024, 1024)),
	}
	config := procgen.terrain_default_config(fuzzx.next_u64(prng))
	fuzzx.check(ctx, procgen.terrain_generate_chunk(config, &chunk), "terrain generation failed")
	view, ok := asset.mesh_view(&chunk.mesh)
	fuzzx.check(ctx, ok, "generated mesh rejected")
	fuzzx.check(ctx, asset.mesh_validate(view), "generated mesh invalid")
	fuzzx.check(
		ctx,
		int(chunk.placement_count) <= procgen.TERRAIN_MAX_PLACEMENTS,
		"placement capacity exceeded",
	)
}

exercise_volume :: proc(ctx: ^fuzzx.Ctx, prng: ^fuzzx.Prng) {
	assert(ctx != nil, "exercise_volume: nil context")
	assert(prng != nil, "exercise_volume: nil prng")
	storage: Storage
	seed := fuzzx.next_u64(prng)
	recipe := procgen.terrain_abstract_recipe_v3(seed)
	origin := [3]f32 {
		f32(fuzzx.int_range(prng, -128, 128)),
		f32(fuzzx.int_range(prng, -128, 128)),
		f32(fuzzx.int_range(prng, -32, 32)),
	}
	request := procgen.Terrain_Volume_Request_V3{origin, {4, 4, 4}, 4}
	buffer := procgen.Terrain_Volume_Buffer_V3 {
		density_halo = storage.volume_density[:],
		mesh = {
			id = 2,
			vertices = storage.volume_vertices[:],
			indices = storage.volume_indices[:],
			primitive = .Triangles,
		},
	}
	if procgen.terrain_generate_volume_v3(&recipe, request, &buffer) {
		view, ok := asset.mesh_view(&buffer.mesh)
		fuzzx.check(ctx, ok && asset.mesh_validate(view), "volume mesh invalid")
	}
}

package fuzz_procgen

import "core:fmt"
import "ingot:asset"
import fuzzx "ingot:fuzz/fuzzx"
import "ingot:procgen"

ITERATIONS_DEFAULT :: 10_000

Storage :: struct {
	vertices: [procgen.TERRAIN_CHUNK_VERTICES]asset.Vertex,
	indices:  [procgen.TERRAIN_CHUNK_INDICES]u32,
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

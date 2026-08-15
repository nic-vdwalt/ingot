# Procedural generation

Ingot's procedural pipeline separates deterministic data generation from GPU
ownership. A seed and world coordinates produce cooked assets and placement
records; `scene` turns those records into a bounded draw list; only `scene_gfx`
uploads or renders them.

## Package flow

```text
seed + coordinates -> procgen -> asset -> scene -> draw list -> scene_gfx -> gfx
```

`asset`, `procgen`, and `scene` must not import `gfx`. This permits tests and
fuzz harnesses to run without a window or GPU. `examples/procgen_world` owns
camera controls and presentation but no reusable generation logic.

## World basis

All generated data uses Ingot's right-handed ROS basis: +X forward, +Y left,
+Z up. Noise samples absolute X/Y world coordinates. Neighboring chunks must
therefore produce byte-identical shared edge positions and normals.

## Initial budgets

| Budget | Initial value |
|---|---:|
| Terrain quads per edge | 32 |
| Vertices per terrain chunk | 1,089 |
| Indices per terrain chunk | 6,144 |
| Placement candidates per chunk | 256 |
| Scene objects | 4,096 |
| Draws per frame | 2,048 |
| Resident GPU meshes | 256 |
| Instances per encoded draw | 256 |

Capacity exhaustion is an operating condition. Generation rejects insufficient
caller buffers; scene draw lists saturate and count overflow; residency rejects
uploads and counts failures. No stage grows storage without a declared bound.

## Terrain milestone

The first milestone generates a 4x4 terrain working set from one seed. It
derives height, moisture, temperature, slope, biome, normals, UVs, bounds, and
placement candidates. The existing scalar vertex channel visualizes the result
between low and high material colors, avoiding a renderer change in milestone
one.

Acceptance is data-first: repeated generation is byte-identical, adjacent
chunks share edges, every index is valid, bounds contain all vertices, placement
counts remain bounded, draw-list order is stable, and culling is conservative.

## Authored mesh variants

`mesh_scale_variant` derives a validated mesh from an authored `Mesh_View` and
caller-owned `Mesh_Buffer`. Recipes are deterministic data: callers retain the
source topology and material UVs, supply positive axis scales, and choose the
derived mesh identity. Derivation is intended for bounded initialization or
worker-residency stages, never per-frame rendering. More complex generators may
build on the same caller-owned storage and validation contract.

`mesh_deform_variant` composes positive axis scale with seeded, low-frequency
radial and vertical displacement. Noise is keyed by normalized source position,
so coincident vertices split by UV or authored normal seams move together. The
generator preserves indices, UVs, and scalar values; rebuilds normals within
each exported index topology; optionally re-grounds the result; and recomputes
its AABB. Degenerate triangles reject the whole derivation and output counts
remain unpublished on failure.

Derived identity consists of the source mesh ID,
`MESH_DEFORM_GENERATOR_VERSION`, and every recipe field. Results are repeatable
for the same target and build. Callers must invalidate persisted variants when
the generator version changes; cross-architecture floating-point byte identity
is not part of the current contract. Derivation remains initialization or
worker-residency work and must not run per frame.

## Follow-on milestones

1. Terrain LOD, seam transitions, streaming, upload budgets, biome texture
   blending, normal maps, and water.
2. Deterministic tree species/placement, generated mesh variants, instancing,
   alpha-cutout foliage, and impostor LOD.
3. Bounded building grammars, modular facade/roof generation, instancing, and
   collision/navigation proxy output.
4. Versioned cooked files, worker residency, hot reload, and selective glTF
   import for authored modules.

## Example

Run the native consumer with:

```sh
odin run examples/procgen_world -collection:ingot=.
```

Build the same source for the browser with:

```sh
bash build_web.sh examples/procgen_world
```

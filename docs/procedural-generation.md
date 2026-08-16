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

## Terrain fields V2

V1 terrain sampling and chunk generation remain compatibility APIs. V2 adds a
semantic recipe version and caller-owned fields for applications that need a
reusable world-generation product rather than independent point samples.

V2 composes continental, mountain, ridge, hill, and detail signals, then fills
a one-cell height halo before deriving centered gradients, slope, climate, and
data-driven biome-profile blends. Generation validates every recipe and output
capacity before publication. Storage remains bounded by
`TERRAIN_FIELD_MAX_EDGE_V2`; no generator allocation or GPU dependency is added.

V2 output is deterministic for the same target and build. Cross-architecture
floating-point byte identity is not guaranteed. Consumers using generated data
authoritatively must quantize it, persist or version its recipe, and reject
incompatible semantic versions.

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

## Evolving creature meshes

`creature_mesh_evolve` derives a progression-dependent creature from an authored
triangle mesh without changing its topology. Applications map game-specific
strength, vitality, agility, age, genetics, or level into normalized
`Creature_Morphology` fields. The generator remains independent of game rules
and preserves source indices, UVs, and scalar values while rebuilding normals
and bounds.

Profiles interpret the authored model in Ingot's +X forward, +Y left, +Z up
basis. They identify the head/front threshold and torso center, then bound region
falloff and maximum deformation. Maturity blends all requested morphology from
the source proportions. Stature, bulk, muscle, head scale, and reach affect
stable authored-space regions; seeded curvature and surface detail add organic
variation. Displacement depends on source position rather than seam-specific
attributes, so coincident vertices split for UVs or normals remain together.

A consumer loads or cooks the base mesh once, builds a recipe whenever its
progression state changes, and calls `creature_mesh_key` before doing generation.
If the key differs from the resident key, it regenerates into caller-owned
storage outside the render hot path, then updates or replaces the resident GPU
mesh. The key includes source mesh identity, source content identity, generator
version, seed, level, progression revision, morphology, and every profile field.
Persisted variants must be invalidated when the generator version changes.

Generation rejects malformed sources, non-triangle topology, non-finite or
out-of-range controls, zero-span source bounds, insufficient destination
capacity, and degenerate output. Destination counts remain zero after failure.
Generation allocates no storage, imports no GPU package, and must not run each
frame. Same-target/build results are deterministic; cross-architecture floating
point byte identity is not guaranteed.

## Follow-on milestones

1. Bounded erosion, drainage, river/lake generation, and sediment fields.
2. Terrain LOD, seam transitions, streaming, upload budgets, biome texture
   blending, normal maps, and water.
3. Deterministic tree species/placement, generated mesh variants, instancing,
   alpha-cutout foliage, and impostor LOD.
4. Bounded building grammars, modular facade/roof generation, instancing, and
   collision/navigation proxy output.
5. Versioned cooked files, worker residency, hot reload, and selective glTF
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

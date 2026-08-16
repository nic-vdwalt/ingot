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

Biome blends are local suitability data, not spatial ownership. Consumers that
need categorical terrain call `terrain_resolve_biome_regions` over their complete
authoritative domain. The resolver publishes one hard biome owner and one
4-neighbor-connected patch ID per sample, with deterministic minimum-component
merging. Resolving independent chunks without a shared stitch domain is invalid
because component size and patch identity depend on neighboring cells.

V2 output is deterministic for the same target and build. Cross-architecture
floating-point byte identity is not guaranteed. Consumers using generated data
authoritatively must quantize it, persist or version its recipe, and reject
incompatible semantic versions.

## Volumetric terrain V3

V3 keeps V1 and V2 unchanged and adds a signed-density product for terrain that
cannot be represented by one height per X/Y coordinate. Positive density is
solid. The abstract preset composes the V2 surface with sharper mountains,
overhang displacement, disconnected floating masses, and subtractive cave
signals. The normal preset sets every abstract strength to zero and publishes
the exact V2 primary-surface height.

`Terrain_Parameters_V3` exposes vertical bounds, voxel scale, mountain shape,
floating-land spacing/altitude/radius/thickness/breakup, cave altitude and
shape, and the upward-normal policy for a designated buildable surface. Use
`terrain_normal_recipe_v3`, `terrain_abstract_recipe_v3`, or validated
`terrain_custom_recipe_v3`; persisted consumers must store the V3 semantic
version and their selected parameters.

`terrain_generate_volume_v3` samples absolute world coordinates into a
caller-owned halo and emits a bounded triangle mesh. Capacity is calculated by
`terrain_volume_requirements_v3` and checked before mesh counts are published.
The same density coordinates and centered gradients are used at neighboring
chunk boundaries. Volume meshes contain the primary ground boundary and
therefore replace, rather than overlay, a heightfield mesh. Volume
`Vertex.scalar` describes surface orientation; it is not a biome ID. Consumers
map resolved biome fields to volume materials explicitly. V3 does not define
navigation, volumetric editing, cave water, or multi-level placement; consumers
choose how its primary surface participates in simulation.

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

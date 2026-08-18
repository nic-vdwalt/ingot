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

V2 composes continental, mountain, ridge, hill, detail, and inland-basin
signals, then fills one-cell height and landform halos before deriving centered
gradients, slope, climate, and data-driven biome-profile blends. Generation
validates every recipe and output capacity before publication. Storage remains
bounded by `TERRAIN_FIELD_MAX_EDGE_V2`; no generator allocation or GPU
dependency is added.

Climate and continentalness are contrast-shaped by `climate_contrast` and
`continental_contrast`. The fractal stack averages octaves and divides by summed
amplitude, so its raw output occupies roughly the middle fifth of the unit
range; without expansion about the midpoint, profile windows at the dry and cold
extremes are unreachable and every seed produces the same distribution. Both
parameters must be at least `TERRAIN_CONTRAST_MIN_V2`, and a value of exactly 1
is the identity. The clamp at 0 and 1 is intended: saturation is what produces
large uniform biome cores rather than a permanent gradient.

Biome profiles score five axes: landform height, continentalness, moisture,
temperature, and landform slope. Continentalness is what distinguishes an
inland sample from a coastal one at the same elevation, so a consumer can
separate a lake from an ocean without a second classification pass.

Height and landform are two surfaces from one evaluation of the same stack.
`height` is the ground a consumer renders and walks on: base elevation, ridged
uplift, hills, and fine detail. `landform` omits the hill and detail octaves.
Classification reads the landform pair -- `Terrain_Sample_V2.landform` and
`landform_slope` -- while `height`, `slope`, and the derivatives keep their
previous meaning. Hills exist to make ground look uneven, not to relabel it: at
a hill height of 5 over a ~71-unit wavelength a single bump reaches a slope near
0.44, which is enough to trip a rock profile's slope floor on otherwise uniform
ground and fragment one province into a mottle of six.
`terrain_height_terms_prevalidated_v2` publishes both surfaces from a single
evaluation, so a caller that needs the pair never pays for the stack twice.

`moisture_bias` and `temperature_bias` shift a climate channel additively after
contrast and before the final clamp, so one seed can be a globally dry world and
another a globally cold one. Contrast only widens a distribution about its
midpoint; without a bias every seed shares one climate centre. Both are bounded
by `TERRAIN_CLIMATE_BIAS_MAX_V2` because a larger value cannot move a clamped
channel further.

`latitude_offset` is the world-Y the warm band sits on. With the equator pinned
to zero, every world shares one north-south gradient regardless of seed.

`coast_jitter` is the strength of the hill-wavelength perturbation applied to
the land mask after the coast smoothstep. A recipe that wants province-scale
landmasses turns it down; one that wants a broken archipelago turns it up. Zero
is a legal value and yields the smoothstep coastline unmodified.

`basin_noise`, `basin_threshold`, `basin_fade`, and `basin_depth` carve inland
depressions toward a floor at `sea_level - basin_depth`, gated to land and away
from uplift. Interpolating toward a floor rather than subtracting a fixed depth
guarantees the depression reaches water however high the surrounding land sits,
and yields a smooth shoreline. A `basin_depth` of zero disables carving.

Biome blends are local suitability data, not spatial ownership. Consumers that
need categorical terrain call `terrain_resolve_biome_regions` over their complete
authoritative domain. The resolver publishes one hard biome owner and one
4-neighbor-connected patch ID per sample, with deterministic minimum-component
merging. Resolving independent chunks without a shared stitch domain is invalid
because component size and patch identity depend on neighboring cells.

The resolver buckets cell indices by component with a counting sort each pass,
so choosing a merge target walks only that component's own cells.
`Terrain_Biome_Region_Scratch` therefore requires `component_offsets` of at
least `cells + 1` entries and `component_cells` of at least `cells`. The
per-component grid sweep this replaced was quadratic once most components fell
below the minimum, which is exactly what a province-scale `minimum_cells`
produces.

The V2 recipe version is `4`. Version `3` lacked climate bias, the movable
equator, and the tunable coast jitter, and classified on the full height and
slope rather than the landform pair. Version `2` also lacked the
continentalness biome axis, the contrast parameters, and basin carving. Both
classified and shaped a seed differently, so worlds persisted against either
must be regenerated rather than reinterpreted.

V2 output is deterministic for the same target and build. Cross-architecture
floating-point byte identity is not guaranteed. Consumers using generated data
authoritatively must quantize it, persist or version its recipe, and reject
incompatible semantic versions.

## Spherical terrain V4

V4 keeps V1, V2, and V3 unchanged and maps the heightfield product onto a closed
sphere. Its tangent-adjusted cube-face parameterisation gives consumers six
bounded square charts while every surface signal samples three-dimensional
world-scale positions. Shared face edges therefore evaluate the same direction
and noise coordinates instead of carrying the discontinuity produced by six
independent 2D domains.

`terrain_face_direction_v4`, `terrain_face_locate_v4`, and
`terrain_face_basis_v4` publish the parameterisation and its local radial frame.
Noise samples `direction * radius`, so a recipe frequency remains measured in
world units and existing province wavelengths transfer without dividing by the
planet radius. Tangent derivatives step by `derivative_step / radius` radians.

V4 preserves V2's distinction between rendered height and landform. One
spherical stack publishes both surfaces; four tangent probes derive full and
landform slopes. Biome profiles classify on landform while `upward_normal` and
`buildable` describe the full surface. Latitude is angular and controlled by
`latitude_offset_radians` and `latitude_half_extent_radians`; the embedded V2
world-Y offset must remain zero so it cannot be silently mistaken for a planet
rotation.

The V4 recipe version is `1`. Generation allocates no storage, imports no GPU
package, and is deterministic for the same target and build. Cross-architecture
floating-point byte identity is not guaranteed. V4 defines the primary surface,
not a radial signed-density volume: caves, overhangs, navigation, water flow,
face adjacency, editing, and mesh construction remain consumer responsibilities.

## Volumetric terrain V3

V3 keeps V1 and V2 unchanged and adds a signed-density product for terrain that
cannot be represented by one height per X/Y coordinate. Positive density is
solid. The abstract preset composes the V2 surface with sharper mountains,
overhang displacement, disconnected floating masses, and subtractive cave
signals. The normal preset sets every abstract strength to zero and publishes
the exact V2 primary-surface height.

The V3 recipe version is `6`. Version `5` embedded a version-3 surface recipe,
which lacked climate bias and classified on the full height; version `4`
embedded a version-2 one; version `3` differed in geometry and in the shape of
its caller-owned buffers. Worlds persisted against any of them must be
regenerated rather than reinterpreted; this is exactly the situation the stored
semantic version exists to detect.

`Terrain_Surface_V3` publishes `landform` alongside `height`. Both are shaped by
the V3 mountain transform, and the classification slope is taken from shaped
landform neighbours because that transform is non-linear -- scaling a peak
changes how steep it reads. `slope`, `upward_normal`, and `buildable` continue
to describe the full height, which is the surface a player walks on.

`Terrain_Parameters_V3` exposes vertical bounds, voxel scale, mountain shape,
floating-land spacing/altitude/radius/thickness/breakup, cave altitude and
shape, the upward-normal policy for a designated buildable surface, and the
triplanar UV scale. Use `terrain_normal_recipe_v3`, `terrain_abstract_recipe_v3`,
or validated `terrain_custom_recipe_v3`; persisted consumers must store the V3
semantic version and their selected parameters.

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

Cave, overhang, and island-breakup signals sample a genuine 3D field through
`fractal_3d`. Composing 2D slices with an axis swizzle, as version 3 did, made
every tunnel extrude along whichever axis its slice omitted, which is the
artifact a volumetric product exists to avoid.

Isosurface crossings are welded on the identity of the lattice edge they cut, so
a vertex shared by several triangles is stored once and the index buffer carries
real connectivity. The key is a pair of integer halo indices, never a float
comparison, so two cells that share a face cannot disagree. Welding typically
reduces the vertex count around fivefold at an unchanged index count; it does
not move the surface. `terrain_volume_count_v3` reports the exact counts a
request will produce so a streaming consumer can size real buffers instead of
the per-cell worst case.

Occupancy is a separate, cheaper question. `terrain_volume_occupancy_v3` bounds
each column's density from the recipe alone -- overhang by its strength, carving
by `(1 - cave_threshold) * cave_strength`, floating mass by
`floating_strength * floating_thickness` inside its altitude band -- and answers
from one 2D noise stack per column rather than a full three-dimensional pass.
The answer is conservative: `Mixed` never promises a surface, but `Empty` and
`Solid` are certain. A uniform chunk is an ordinary result in a streaming world,
so generation reports it through `Terrain_Volume_Result_V3` with zero counts
rather than failing.

## Cooking generated meshes

`cook_chain_from_policy` and `cook_chain_from_clusters` turn a generated
`Mesh_View` into an `asset.Cooked_Mesh_Chain`, which `asset.cooked_mesh_v2_encode`
writes as `INGMESH2`. The policy path simplifies repeatedly at fixed ratios; the
cluster path takes the levels `cluster_build` already produced and adds what the
format needs that the builder does not supply: a screen threshold per level,
indices rebased to their own level's vertex span, and strictly increasing error.

Screen thresholds match `tools/mesh_cook.py`, so an asset cooked at runtime and
the same asset cooked offline select the same level at the same distance. A DAG
and a discrete chain are alternatives rather than companions, because the DAG
already carries every level's geometry. A source needing more than
`COOK_LOD_MAX_LEVELS` levels is rejected rather than truncated; raise
`simplify_ratio` to converge in fewer.

Cooking is initialization or worker-residency work, the same contract
`mesh_deform_variant` and `creature_mesh_evolve` carry. It must not run per
frame.

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
5. Worker residency, hot reload, and selective glTF import for authored modules.
   Versioned cooked files are delivered: see *Cooking generated meshes* above.

## Example

Run the native consumer with:

```sh
odin run examples/procgen_world -collection:ingot=.
```

Build the same source for the browser with:

```sh
bash build_web.sh examples/procgen_world
```

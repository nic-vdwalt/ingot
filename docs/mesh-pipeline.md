# Mesh pipeline

`ingot:mesh` holds the deterministic mesh-processing stages that sit between a
generated or authored `asset.Mesh_View` and cooked `INGMESH2` bytes: quadric
simplification (`simplify_mesh`), vertex-cache and fetch ordering
(`optimize_mesh`), cluster DAG construction (`cluster_build`), LOD-chain cooking
(`cook_chain_from_policy`, `cook_chain_from_clusters`), and authored mesh
variants (`mesh_scale_variant`, `mesh_deform_variant`).

The package imports `ingot:asset` and `ingot:noise`, never `gfx`, so every stage
runs in tests and tools without a window or GPU. Every stage writes into
caller-owned storage sized by a matching `*_scratch_size` or requirements
procedure and allocates nothing itself.

World generation (terrain fields, volumes, water, feature placement, creature
morphology) is not part of Ingot. It lives in the forgecore repository as
`forgecore:worldgen`, which consumes this package and `ingot:noise`.

```text
generator or importer -> asset.Mesh_View -> mesh -> asset (INGMESH2) -> scene -> scene_gfx -> gfx
```

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
`mesh_deform_variant` carries. It must not run per
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

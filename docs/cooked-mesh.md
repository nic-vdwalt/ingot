# Cooked static meshes

`ingot:asset` accepts versioned `INGMESH1` bytes and exposes validated mesh
views through caller-owned storage. Import tools own source-format and basis
conversion; runtime code never parses Blender or glTF files. The broader glTF,
material, texture, and scene pipeline remains described in
[3d-content-pipeline-plan.md](3d-content-pipeline-plan.md).

## Format

All values are little-endian. The header contains the eight-byte `INGMESH1`
magic followed by `version`, `mesh_count`, `vertex_count`, and `index_count` as
`u32`. Version 1 uses a 24-byte header.

Each 44-byte mesh record contains five `u32` values (`id`, `first_vertex`,
`vertex_count`, `first_index`, `index_count`) followed by minimum and maximum
bounds as six `f32` values. Records are sorted by non-zero ID and their vertex
and index spans are contiguous and exhaustive.

The record table is followed by 36-byte vertices and then `u32` indices. A
vertex contains position and normal as three `f32` values each, one scalar, and
UV0 as two `f32` values. Indices are local to their mesh. Version 1 accepts only
indexed triangle meshes.

`cooked_mesh_decode` validates the complete file before exposing views. It
rejects unknown versions, truncation, trailing bytes, capacity overflow,
invalid or overlapping records, non-finite attributes, invalid bounds, and
out-of-range indices. Storage is supplied by the caller and no filesystem or
GPU policy exists in `ingot:asset`.

## Coordinate and scalar contract

Cooked positions and normals use Ingot's right-handed ROS basis: +X forward,
+Y left, +Z up, with outward counter-clockwise winding. Blender vectors are
converted from `(X right, Y forward, Z up)` to `{Y, -X, Z}` exactly once during
export.

The scalar channel remains application-defined. TerraForger uses `0` for rigid
bark and rocks, `1` for wind-driven foliage, and `1.5` for grass wind and
distance dithering.

## Blender exporter

The exporter requires Blender's bundled `bpy` and `bmesh`; it has no pip
dependencies. Production asset regeneration should use the Blender major/minor
recorded by the consuming project once its first source scene is approved.

```sh
blender --background --python tools/blender_ingmesh_export.py -- \
  --input ../terraforger/assets/source/flora.blend \
  --output ../terraforger/assets/generated/flora.ingmesh
```

Pass `--check` to regenerate in memory and fail if the committed output differs.
The exporter evaluates modifiers, triangulates geometry, splits vertices by
position/normal/UV/scalar, canonicalizes negative zero, sorts meshes by ID, and
writes atomically.

Projects with multiple bundles can pass `--manifest path.json`. Version 1
manifests contain a `meshes` array whose records have exactly `id`, `name`,
`group`, `grounded`, and `materials` fields. IDs and names must be unique,
materials must be exporter-supported, and `grounded: true` requires local
minimum Z at zero. Setting it false preserves shared coordinates for separately
drawn material components; the consuming project must validate the assembled
asset's bounds and grounding.

TerraForger's source scene contains `Conifer_A`, `Conifer_B`, `Broadleaf`,
`Grass_Upright`, `Grass_Crossed`, `Grass_Reed`, `Boulder_A`, `Boulder_B`,
`Boulder_C`, `Rock_A`, and `Rock_B`, with `ingot_mesh_id` values 1 through 11.
The only accepted materials are `TF_Bark`, `TF_Foliage`, `TF_Grass`, `TF_Rock`,
and `TF_Dry`. Objects require applied scale, an active UV layer, and minimum
local Z at ground level.

## Grounded LODs and whole-blade grass

For version 2 export, `grounded: true` now protects referenced root vertices
within the exporter's ground tolerance during discrete simplification. Every
emitted discrete or clustered level is checked for grounding, including its
packed or float32 stored positions. Cluster topology is unchanged; a detached
cluster level fails cooking. Targets yield to constraints: a generic chain may
contain fewer levels rather than duplicate geometry or lose its roots. Existing
Python callers default to `grounded=False`; vertex layouts and INGMESH2 are unchanged.

Use `"lod_policy": "grass_blades_2"` for explicitly authored independent blades.
Each source polygon must have an integer FACE attribute named `ingot_blade_id`.
Assign the same nonnegative ID to every segment and both sides of one blade.
IDs need not be contiguous. Evaluated mesh triangulation carries these IDs to
triangles; split normals and UVs never determine blade identity. Missing, malformed
or lost metadata is an error, not an implicit fallback to `grass_2`.

The policy retains complete blades near a 25% index target, selected deterministically
for root distribution, height and root extent. It keeps at least one blade and
requires a strictly cheaper second level. Unequal blade costs can miss the nominal
target; ties favor lower total cost. A single-blade asset cannot use this policy.
The fine level retains all geometry. Coarse vertices, normals, scalar values, UVs
and triangle winding are checked against the selected source triangles.

Every blade must be grounded, have nonzero height, use grass scalar 1.5, and have
paired opposite coverage. Coplanar patch boundaries are compared after internal
edges cancel, permitting opposite quad triangulation diagonals. Degenerate faces,
missing sides, disconnected segments, crossing boundaries and nonmanifold junctions
fail with a mesh/blade diagnostic. Exact source positions identify geometric edges;
near-but-not-equal positions are not silently welded. Validation uses a 1e-7 plane
and normal-alignment tolerance and a 1e-14 cross-product magnitude floor.

Limits are 256 blades per mesh and 128 triangles per blade. Progressive selection
and representative-distance work are bounded by O(B² + T); per-component geometric
checks have a fixed 128-triangle ceiling. Omitted-geometry error is a conservative
bound to retained root/tip representatives, not QEM collapse error, and can be
larger than perceived silhouette change. Inspect coarse previews before approval.

`grass_blades_2` cannot be combined with clustered cooking or version 1 output.
Legacy `grass_2` remains available. No runtime metadata or Odin simplifier changes
are required. Regenerate opted-in bundles and measure decoder capacities; ground
locks can change level counts for non-grass meshes too.

From the workspace root, run the dependency-free and Blender integration tests:

```sh
python3 -m unittest discover ingot/tools
tools/blender-5.2.0/Blender.app/Contents/MacOS/Blender --background \
  --python-exit-code 1 --python ingot/tools/test_blender_grass_export.py
```

The Blender tests cover saved-scene export, triangulation identity, both diagonal
conventions, missing metadata, stored grounding, format rejection and freshness.
Their temporary files remain inside the workspace and are removed after testing.

## Non-goals

Version 1 does not contain textures, PBR materials, tangents, UV1, vertex
colors, node hierarchies, animation, skinning, morph targets, or generated LODs.
Those features belong to later versions or the general glTF scene pipeline.

LOD chains, cluster LOD, and packed vertices arrived in
[`INGMESH2`](cooked-mesh-v2.md). Version 1 remains supported unchanged, and
`cooked_mesh_decode` reads a version 2 bundle by projecting its LOD 0 onto the
version 1 result, so callers here need no change.

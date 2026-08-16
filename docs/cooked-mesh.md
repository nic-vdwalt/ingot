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

## Non-goals

Version 1 does not contain textures, PBR materials, tangents, UV1, vertex
colors, node hierarchies, animation, skinning, morph targets, or generated LODs.
Those features belong to later versions or the general glTF scene pipeline.

LOD chains, cluster LOD, and packed vertices arrived in
[`INGMESH2`](cooked-mesh-v2.md). Version 1 remains supported unchanged, and
`cooked_mesh_decode` reads a version 2 bundle by projecting its LOD 0 onto the
version 1 result, so callers here need no change.

# Cooked static meshes, version 2

`INGMESH2` adds what [version 1](cooked-mesh.md) deferred: a per-mesh LOD chain,
an optional cluster DAG, and 16-byte packed vertices. Version 1 files stay
readable and version 1 callers stay source-compatible; see *Compatibility*
below. The cluster structure itself is described in [cluster-lod.md](cluster-lod.md).

## Why a second version

Version 1 stores one resolution per mesh. That was the right scope for a single
hand-authored bundle, but it forces the import tool to pick one triangle budget
per asset and live with it at every distance. TerraForger's practical ceiling —
16,384 vertices and 49,152 indices for a whole bundle — is a symptom of the same
thing: without LODs, every triangle you cook is a triangle you draw.

Version 2 changes three costs at once:

- **Vertex size**: 36 bytes to 16, a 2.25x reduction in file size and
  vertex-fetch bandwidth.
- **Triangles drawn**: a chain or a DAG lets the runtime spend detail where it
  is visible.
- **Mesh count**: the 256-mesh ceiling becomes 1024, and the real bound moves to
  total bytes, which is what actually constrains an upload.

## Layout

All values are little-endian.

| Section         | Size                              |
| --------------- | --------------------------------- |
| header          | 48                                |
| mesh records    | `mesh_count` × 68                 |
| LOD records     | `lod_count` × 24                  |
| cluster records | `cluster_count` × 40              |
| group records   | `group_count` × 32                |
| vertices        | `vertex_count` × (16 packed \| 36) |
| indices         | `index_count` × 4                 |

### Header

| Offset | Type    | Field           |
| ------ | ------- | --------------- |
| 0      | `u8[8]` | `INGMESH2`      |
| 8      | `u32`   | `version` (2)   |
| 12     | `u32`   | `mesh_count`    |
| 16     | `u32`   | `lod_count`     |
| 20     | `u32`   | `cluster_count` |
| 24     | `u32`   | `group_count`   |
| 28     | `u32`   | `vertex_count`  |
| 32     | `u32`   | `index_count`   |
| 36     | `u32`   | `flags`         |
| 40     | `u32`   | reserved (0)    |
| 44     | `u32`   | reserved (0)    |

`flags` bit 0 selects packed vertices, bit 1 declares a cluster DAG. Any other
bit set is rejected, and bit 1 must agree with `cluster_count > 0`.

### Mesh record (68 bytes)

Seven `u32` — `id`, `lod_first`, `lod_count`, `cluster_first`, `cluster_count`,
`group_first`, `group_count` — then six `f32` of position bounds (minimum then
maximum) and four `f32` of UV bounds.

IDs are non-zero and strictly increasing. Every table is walked once in record
order, so each mesh's LOD, cluster, and group spans must begin exactly where the
previous mesh's ended, and the last must exhaust the table.

### LOD record (24 bytes)

Four `u32` — `first_vertex`, `vertex_count`, `first_index`, `index_count` — then
`error` and `screen_height_threshold` as `f32`.

Within a mesh, `error` is strictly increasing and `screen_height_threshold` is
strictly decreasing. Equality is rejected rather than tolerated: two levels that
qualify at one threshold would make the runtime's choice depend on iteration
order. Vertex and index spans are contiguous across the whole file, not just
within a mesh.

`error` is geometric error against LOD 0 in mesh units.
`screen_height_threshold` is the projected height in pixels below which the level
is preferred, so a runtime walks the chain forward and stops at the first level
whose threshold the mesh still exceeds.

### Cluster record (40 bytes)

`first_index` and `index_count` as `u32`, a bounding sphere as three `f32` of
centre plus one of radius, then `error`, `parent_error`, `group`, and `level`.
`level` is stored as `u32` and read as the low byte.

### Group record (32 bytes)

`first_child` and `child_count` as `u32`, a bounding sphere as four `f32`,
`error` as `f32`, and `level` as `u32`.

## Packed vertices

`Vertex_Packed` is 16 bytes:

| Bytes | Field                                                |
| ----- | ---------------------------------------------------- |
| 0–5   | position, three `u16` quantized into the mesh bounds  |
| 6–7   | normal, two `i8` of octahedral projection            |
| 8–11  | UV, two `u16` quantized into the mesh UV bounds       |
| 12    | scalar, one `u8` over the documented 0–2 range        |
| 13–15 | padding, must be zero                                |

Quantization is derived from the mesh record's own bounds, so a decoder needs no
side table and two encoders of the same mesh cannot disagree. Positional error
is bounded by half a quantization step per axis; `asset.vertex_position_tolerance`
returns that bound, and both the tests and the cook tool compare against it
rather than a hand-picked epsilon.

UV bounds are **measured**, not assumed to be `[0,1]`. An atlas-repacked mesh
therefore keeps full precision instead of spending most of its range on empty
margin, and a tiling mesh round-trips instead of being silently clamped.

The octahedral normal is accurate to roughly two degrees. That is the deliberate
trade for two bytes; it is fine for foliage, rock, and terrain, and would not be
for a mirror-finish hero asset. Such an asset should use the unpacked flag.

## What the decoder rejects

`cooked_mesh_v2_decode` validates the complete file before exposing anything. It
rejects everything version 1 does — unknown version, truncation, trailing bytes,
capacity overflow, invalid or non-contiguous records, non-finite attributes,
invalid bounds, out-of-range indices — plus:

- unknown or self-contradictory `flags`
- LOD errors or screen thresholds that are not strictly monotonic
- LOD spans that overlap or leave a hole
- more than `COOKED_MESH_V2_MAX_MESH_LODS` (8) levels on one mesh
- a cluster whose index span crosses a LOD boundary
- any cluster DAG that fails `cluster_dag_validate`

Storage is supplied by the caller. There is no filesystem or GPU policy in
`ingot:asset`.

## Writing a bundle

`cooked_mesh_v2_encode` is the in-process writer, and
`cooked_mesh_v2_encoded_size` reports the byte count it will produce so a caller
can size storage first. It exists so a procedurally generated mesh can be cooked
at runtime without shelling out to `tools/mesh_cook.py`, which remains the
offline tool.

The writer refuses everything the reader refuses and reports the same
`Cooked_Mesh_Fault`, so a producer and a consumer describe a bad bundle in one
vocabulary rather than two private ones. Learning at cook time that a chain's
LOD errors are not monotonic names the offending mesh; learning it at load time
names a byte offset in a file someone has already shipped. Nothing is written
when the answer is `.Capacity`.

Two layout details a writer has to get right, and which the round-trip test
pins:

- **LOD indices are local to their own level's vertex span**, the same way
  version 1 stores them local to a mesh.
- **Cluster `first_index` is file-global**, because `cluster_dag_validate` is
  given the whole file's index count and cluster spans are nested inside
  file-global LOD spans.

The oracle is the round trip — encode, decode, compare — which is why the writer
lives beside the reader instead of in the package that generates geometry. It is
additionally checked byte for byte against the independent test writer in
`cooked_mesh_v2_test.odin`, so agreeing with the format is distinguishable from
agreeing with itself.

`ingot:procgen` supplies the geometry half through `cook_chain_from_policy` and
`cook_chain_from_clusters`; see
[procedural-generation.md](procedural-generation.md).

## Index order is part of the contract

A cooked level's index order is not arbitrary. Every level leaves the cook in
optimised order — vertex cache, then overdraw, then vertex fetch, in that order,
because each pass assumes the previous one has run. Level 0 is included even
though it is the source geometry rather than a simplification of it.

Two implementations produce that order and they must agree:
`procgen/mesh_optimize.odin` for the runtime cook and `tools/mesh_cook.py` for
the offline one. Neither can call the other — the offline cook runs inside
Blender's bundled interpreter — so the duplication is structural rather than
accidental, and the only thing keeping it honest is that
`procgen/mesh_optimize_test.odin` and `tools/test_mesh_cook.py` assert the same
golden index order for the same input grid. Change one implementation and the
other's test fails.

Two consequences worth stating outright:

- **Scoring is spelled to be reproducible, not idiomatic.** Forsyth's score uses
  `x**1.5` and `n**-0.5`; both sides instead write `x*sqrt(x)` and `2/sqrt(n)`,
  because `sqrt` is correctly rounded per IEEE-754 and `pow` is not. Equal-
  valence vertices produce exactly tied scores often enough that a last-ulp
  disagreement between two libms would flip a tie and diverge the whole order.
- **Selection is a heap on both sides.** Selecting by scanning every live
  triangle each step is O(T²) — affordable for a prop, a hang for anything
  larger. Both sides now use a heap keyed on `(score, lowest index)`, which
  reproduces the scan's choice exactly rather than approximately: the scan
  walked upward taking a strictly better score, so it too kept the lowest index
  among equals.
- **Rescoring skips what did not change.** A vertex whose modelled cache
  position and remaining valence both held still scores the same as it did, so
  the triangles around it are already correctly ordered. Both sides skip those.
  The skip is exact, which is what lets both take it without diverging — it is
  worth about 25× on a 32k-triangle mesh.

The cluster path is deliberately exempt. A DAG's index order belongs to
`cluster_build`, which stores each cluster as a span into the level's indices;
reordering it would invalidate every span.

Cost, measured on an M-series laptop: 2k triangles in 1.8 ms, 8k in 10 ms, 32k
in 22 ms. That is initialization or worker-residency work and must not run per
frame. Inputs above `SIMPLIFY_MAX_VERTICES` vertices or `SIMPLIFY_MAX_INDICES`
indices are rejected rather than truncated, the same ceiling the simplifier
enforces.

## Compatibility

`cooked_mesh_decode` dispatches on the magic's last byte. A version 1 file
decodes exactly as before. A version 2 file is accepted and **projected onto
LOD 0**, so a caller written before LOD chains existed keeps working against
re-cooked assets without a code change.

The projection needs somewhere to put the chain, so it takes a defaulted
`Cooked_Mesh_V2_Scratch` parameter. Omitting it — which every existing call site
does — rejects a version 2 bundle with `.Capacity` rather than degrading to a
partial read. Adding scratch fields to `Cooked_Mesh_Storage` instead would have
broken every positional struct literal in the codebase, which is why it is a
separate parameter.

`vertex_count` and `index_count` in the projected bundle report the file's
totals, not LOD 0's: the whole payload is resident, and the field has always
meant "how much of the caller's storage is in use".

## Non-goals

Version 2 still does not carry textures, PBR materials, tangents, UV1, vertex
colours, node hierarchies, animation, skinning, or morph targets. Those belong
to the general glTF scene pipeline described in
[3d-content-pipeline-plan.md](3d-content-pipeline-plan.md).

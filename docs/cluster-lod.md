# Cluster LOD

A cooked mesh may carry a directed acyclic graph of triangle clusters instead
of, or alongside, a discrete LOD chain. The graph is built offline by
`ingot:procgen` and validated by `ingot:asset`; `ingot:scene` selects from it at
runtime. The file encoding is in [cooked-mesh-v2.md](cooked-mesh-v2.md).

## What this is and is not

The structure is Unreal's Nanite, reduced to the parts that survive a WebGPU and
Tiger Style constraint set. The valuable idea — a cluster DAG with locked group
borders, built at cook time — is published work built on Cignoni's batched
multi-triangulation and Garland-Heckbert quadric simplification. None of it
needs an exotic GPU feature.

What is deliberately **not** here:

- **No software rasterizer.** WebGPU core has no 64-bit atomics, the extensions
  that would provide them are not portable, and the browser is a first-class
  ingot target.
- **No visibility buffer.** Pointless without the software raster and it fights
  the forward WGSL pipeline.
- **No virtual texturing, ray-tracing proxies, or skinned clusters.** The last
  keeps the fauna boundary intact: `TRELLIS.2` outputs static meshes, and
  rigging them is a different project.

## The selection rule

Every cluster records the geometric error its own level introduced and the error
of the group that replaces it one level up. A cluster is drawn when:

```
error(c) <= threshold  and  parent_error(c) > threshold
```

The threshold is a pixel budget converted to mesh units at the cluster's own
distance (`scene.cluster_screen_error`). Because `parent_error` is strictly
greater than `error`, this selects exactly one level along every path through
the graph — never two, never none. `scene/cluster_build_test.odin` sweeps the
camera across four hundred distances asserting precisely that, because a
boundary where both or neither qualify shows up as doubled geometry or a hole.

The root cluster carries `CLUSTER_ERROR_ROOT`, a finite sentinel rather than an
infinity so it still passes the finiteness checks every other float in the
format must.

## Why it does not crack

Two neighbouring clusters can resolve at different levels in the same frame. The
reason they still meet is entirely in how the parent was built:

1. Clusters are merged into a **group** before simplification.
2. Every vertex the group shares with anything outside it is **locked**.
3. Collapses only ever move a vertex **onto an existing vertex**, never to a
   computed optimal point.

Together these mean a shared boundary position is bit-identical at every level
of the graph. Not "close" — identical, because it was never touched.

There is a second-order trap the naive version of this walks into. Pinning a
vertex is not enough: a locked vertex whose entire incident triangle fan
contracts loses every triangle that references it and vanishes from the output,
which is exactly the crack the lock existed to prevent. So the simplifier
freezes every triangle that touches a locked vertex whole. With all three
corners immovable, none of its edges is ever a collapse candidate and it cannot
become degenerate. The protection is re-derived from the base lock every pass
rather than accumulated, so the frozen region tracks the current geometry
instead of growing without bound.

`procgen/mesh_cluster_test.odin` verifies this directly: it recomputes group
membership from the finished DAG — independently of the builder's own
bookkeeping — and asserts every shared position exists bit-identically in the
parent level.

## Build

`procgen.cluster_build` runs four steps:

1. **Partition.** Triangles are sorted by the Morton code of their centroid and
   cut into runs of at most `CLUSTER_MAX_TRIANGLES` (128). Morton order is a
   weaker partitioner than a graph cut, but it has no dependency, no tuning, and
   is deterministic — which the cook step's byte-for-byte reproducibility needs.
   Sorting also makes each group's triangles a contiguous index range, removing
   the need for a per-group gather index.
2. **Group.** Adjacent clusters are taken `CLUSTER_BUILD_GROUP_SIZE` (4) at a
   time. One sweep over the level's triangles marks every vertex used by more
   than one group; those are the locks.
3. **Simplify.** The group's merged geometry is reduced to half its indices by
   quadric edge collapse, with the locked mask applied.
4. **Re-cluster.** The result is cut into clusters again. Those are the parents.

The loop repeats until one cluster remains, a level fails to shrink, or
`CLUSTER_MAX_LEVELS` (32) is reached. A level that could not shrink is rewound:
the previous level becomes the root set, which is still a valid DAG — just
shallower than the source geometry could have supported.

Errors are forced monotonic. Where a simplification happens to cost nothing
measurable, `CLUSTER_BUILD_ERROR_STEP` separates parent from child anyway, since
equal errors would make the selection rule ambiguous.

## The simplifier

`procgen.simplify_mesh` is Garland-Heckbert with two deliberate departures:

- **Collapses move onto an existing vertex**, not to the optimal point. That
  costs a little quality and buys a lot of safety: no matrix inversion, no
  vertices drifting off the surface, and locked positions stay bit-identical.
- **Topology is resolved over position groups.** A mesh split by normal or UV
  seam — which every exported asset is — would otherwise be pinned everywhere
  and refuse to simplify at all.

It is deterministic, allocation-free beyond caller-supplied scratch, and has no
recursion: candidates are ordered by an iterative heapsort over a total order,
and both the pass count and the per-pass collapse budget are bounded.

Open edges get a Garland-Heckbert boundary plane weighted well above face
planes, so a foliage card's silhouette or a terrain chunk's border survives long
after the interior has gone. `Simplify_Options.lock_boundary` upgrades that from
expensive to immovable, for callers that need the silhouette exactly.

## Bounds

| Constant                      | Value | Why                                                        |
| ----------------------------- | ----- | ---------------------------------------------------------- |
| `CLUSTER_MAX_TRIANGLES`       | 128   | One cluster maps to one GPU workgroup without re-chunking   |
| `CLUSTER_TARGET_VERTICES`     | 64    | Locality target — a connected strip averages ~½ vertex/tri |
| `CLUSTER_MAX_VERTICES`        | 384   | Structural: a 128-triangle cluster has 384 corners          |
| `CLUSTER_MAX_LEVELS`          | 32    | Halving per level covers more than any bundle can hold      |
| `CLUSTER_MAX_GROUP_CHILDREN`  | 16    | Bounds the per-group working buffers                        |
| `SIMPLIFY_MAX_PASSES`         | 32    | Takes any mesh below 1/1000 of its size                     |

## Runtime

`scene.build_cluster_draw_list` is a separate entry point from
`build_draw_list`, not a mode of it, so the discrete LOD path is untouched for
callers that do not cook cluster data. It culls the object's bounds against the
frustum first, then evaluates the selection rule per cluster.

A `Cluster_Draw` is 16 bytes and references its object by index rather than
copying the transform: repeating 64 bytes of matrix across a few thousand
clusters would dominate the list for no benefit, since the caller already owns
the objects it passed in.

Distance is measured to the cluster's bounding sphere *surface*, so a large
cluster the camera sits inside resolves at full detail rather than being treated
as distant.

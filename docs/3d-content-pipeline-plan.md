# 3D Content Pipeline Plan

## Scope

This plan describes how Ingot grows from the explicit GPU 3D escape hatch in
`gfx/gpu3d.odin` into a bounded 3D content pipeline: import, cook, scene build,
residency, and submission. It is written deterministic-simulation-first. Every
stage is designed so that the existing harness in `fuzz/` can drive it with a
seed, without a window, before any renderer work depends on it.

[Testing Ingot](testing.md) describes the harness commands, [Tiger
Style](TIGER_STYLE.md) defines the safety policy, and
[Rendering](rendering.md) documents the current GPU 3D surface this plan
extends.

## Position today

| Surface | State |
|---|---|
| `gfx/gpu3d_pipeline.odin` | Real WebGPU escape hatch: indexed meshes, depth, UV textures, configurable directional lighting, shader depth nudge, bounded instancing, fixed pools (`GPU_3D_MAX_MESHES`, `GPU_3D_MAX_PIPELINES`), generation-checked handles, and counted exhaustion |
| `gfx/frustum.odin` | Allocation-free camera/matrix frustum extraction and conservative bounds tests; visibility primitive for the future `ingot:scene` draw list |
| `gfx/render3d.odin` | Legacy raylib-shaped calls approximated as CPU-projected billboards and discs |
| `gfx/gpu3d.odin` | Compile-compatible surface, several procedures still safe no-ops |
| Asset handling | None. `LoadTexture` reads a file natively and is unavailable on web. There is no mesh import, no cook step, no residency model |

`rendering.md` states that the GPU 3D API is a visualization escape hatch
rather than a scene graph, material system, or asset pipeline. That remains
true until this plan lands; the plan does not retroactively promote the escape
hatch.

## Non-goals

- A general game engine, editor, or authoring tool.
- A physically based material system with an open shader graph.
- Runtime script binding, animation retargeting, or skinning at first.
- Pixel-golden image comparison. Rasterization differs across adapters, so the
  pipeline is validated by data hashes and draw-list snapshots, with the real
  GPU reserved for validation-layer lifetime checks.
- Any relaxation of Tiger Style: no recursion, no unbounded loops, no dynamic
  growth without a declared upper bound.

## Architectural prerequisite: the scene split

The canonical cooked, scene, draw-list, and renderer basis is right-handed ROS:
**+X forward, +Y left, +Z up**. Importers convert positions, normals, tangents,
winding, transforms, animation, cameras, lights, rays, and bounds exactly once.
Cooked data carries no implicit source-format basis and renderers do not repeat
the conversion.

The single decision that makes the rest cheap is mirroring the `ui` / `ui_gfx`
split:

| Package | Responsibility |
|---|---|
| `ingot:asset` | Import and cook. Bytes in, validated cooked asset data out. No `ingot:gfx` import, no GPU, no filesystem policy |
| `ingot:scene` | Scene state, visibility, level of detail, sorting, batching. Emits a bounded 3D draw list as plain data. Must not import `ingot:gfx` |
| `ingot:scene_gfx` | Bridge. Uploads cooked data through `gfx` pools and replays the draw list through `begin_gpu_3d` / `draw_gpu_mesh` / `end_gpu_3d` |

The boundary gate in `scripts/check.sh` that rejects `ingot:gfx` imports under
`ui` extends to `asset` and `scene`. This is what allows import, cook, culling,
level of detail, sorting, and batching to be fuzzed headlessly with the harness
that already exists, and it is the same reason `ui` is inexpensive to fuzz
today.

The draw list is the new contract. It is a fixed-capacity array of records with
explicit handles, transforms, material indices, and sort keys. Overflow is an
operating condition: the list saturates, the overflow is counted in stats, and
the frame still renders.

## Harness mapping

Each stage gets an oracle that fails deterministically under a recorded seed.

| Stage | Target | Oracles |
|---|---|---|
| Import: glTF/GLB, image, WGSL | `fuzz/run.sh asset` - valid template corpus plus `fuzzx.mutate` and `fuzzx.splice`, shaped like `fuzz/net` | No crash, no leak, no bad free. Every rejection is a handled error, never an assertion. Node graph traversal is an explicit bounded stack with a depth limit, so cyclic or deep hierarchies terminate. Index and accessor ranges are validated against buffer extents before any use |
| Cook: normals, tangents, level of detail, mip chains, atlas packing | In-package fuzz tests, following the `input` and `term` pattern | Determinism: identical input produces byte-identical output under two different allocators. Metamorphic: vertex reordering preserves the topology hash, a rigid transform preserves the axis-aligned bounds relationship, level of detail triangle counts are monotonically non-increasing, mip dimensions halve exactly. Roundtrip: import of export is the identity |
| Scene build and draw list | `fuzz/run.sh scene`, headless | Draw list stays inside its bound. No dangling mesh, material, or texture handle. Visibility never drops a fully visible object and never retains a fully excluded one. Sort order is stable for equal keys. `testx.snap` holds a golden textual dump of the draw list |
| Residency, streaming, hot reload | `fuzz/run.sh assetio` - modeled on `wsreconn`: the real worker thread with a scripted I/O tape behind `INGOT_ASSET_SIM`, producing truncated reads, cancellations, evictions, and reload mid-frame. Also run in the `tsan` phase | A partially uploaded mesh is never submitted. Eviction respects the in-flight frame epoch. Reference counts balance across the run. The request queue is bounded and drops are counted |
| GPU upload and lifetime | Extend `fuzz/gfx_frame` with create and destroy of meshes, materials, and 3D targets inside a live pass, under `INGOT_GPU_STRICT` | Zero WebGPU validation messages. Generation checks reject stale handles. Pool exhaustion is counted, never fatal |
| Budgets | Any stage | Declared upper bounds on vertices, draw calls, uploaded bytes per frame, and resident memory are asserted, so a capacity regression fails the harness rather than the user's frame time |

## Harness work this depends on

The pipeline is the forcing function for four improvements that benefit every
existing target as well.

1. **Operation tape and shrinking in `fuzz/fuzzx` (foundation complete).**
   `net` and `interact` record bounded versioned operations and use deterministic
   failure-class-preserving delta debugging. Future asset and scene targets use
   the same opaque operation format and target-owned codecs. Exact replay covers
   every tape; in-process shrinking currently covers structured failures, not
   process-fatal sanitizer or assertion exits.
2. **A virtual clock seam (`INGOT_TIME_SIM`).** Streaming, upload pacing, hot
   reload debounce, and idle behavior become tape-driven instead of
   incidentally deterministic.
3. **A persisted corpus and a seed regression table (complete).**
   `testdata/seeds/manifest.json` is validated and replayed by the Unix and
   Windows standard test gates. Entries are minimized operation tapes, not a
   random bulk corpus.
4. **One PRNG (complete).** `testx/prng.odin` owns harness randomness and
   `fuzzx` aliases it. The dependency-free network simulator retains an isolated
   implementation with a parity test that prevents drift.

A headless WebGPU surface would additionally let `gfx-frame` and the upload
stage join `all` and `soak` instead of requiring a display, but the pipeline
does not block on it.

## Phases

Procedural content establishes the cooked-data and scene contracts before file
import. `examples/procgen_world` is the first end-to-end consumer: deterministic
terrain chunks, biome placements, bounded draw-list construction, residency,
and explicit GPU 3D replay. glTF import follows once generated and imported
content can converge on the same validated cooked representation.

The initial terrain renderer uses the existing scalar two-color material.
Biome texture blending, normal maps, alpha-cutout foliage, trees, buildings,
streaming, and hot reload are additive phases after the vertical slice.

Each phase ends with a green run of the package tests, the strict gate, the web
gate, and its own fuzz target. No phase advances while a source, layout,
ownership, timing, or visual contract differs from the recorded baseline.

### Phase 0 - Harness foundations (complete)

The canonical PRNG, bounded operation-tape codec, deterministic shrinker, and
standard-gate corpus replay are implemented. `net` and `interact` provide the
first target codecs and smoke regressions. Additional harnesses migrate when a
stateful reproducer needs tape stability; that migration is not a prerequisite
for Phase 1.

### Phase 1 - `ingot:asset` import

glTF 2.0 and GLB parsing into a bounded intermediate representation, plus image
decode routed through the existing native path. Rejection is total: malformed
input returns an error with a reason and allocates nothing that outlives the
call. Ships with `fuzz/run.sh asset` and a committed corpus.

### Phase 2 - Cook

Normals, tangents, index optimization, level of detail generation, mip chains,
and a deterministic output container. The cooked form is the only thing the
runtime consumes. Determinism and metamorphic oracles are the acceptance
criteria, not visual inspection.

### Phase 3 - `ingot:scene` and the draw list

Bounded scene storage, transform resolution through an explicit stack,
frustum visibility, level of detail selection, sorting, and batching into the
draw list. Fully headless. `testx.snap` golden dumps are the review artifact.

### Phase 4 - `ingot:scene_gfx` and residency

Upload of cooked data into `gfx` pools, generation-checked handles, the worker
and its scripted I/O seam, eviction bound to frame epochs, and draw-list replay
onto `begin_gpu_3d`. Verified by `fuzz/run.sh assetio`, the `tsan` phase, and
an extended `gfx-frame`.

### Phase 5 - Migration and documentation

Move the CPU-projected calls in `gfx/render3d.odin` onto the real path behind
an explicit opt-in, update `rendering.md` so the escape-hatch language reflects
the new scope, and record the capacity budgets in the compatibility document.

## Risks

- **Import surface size.** glTF is large. The mitigation is a declared subset,
  with anything outside it rejected as an error rather than partially honored.
- **Web parity.** Native decode paths do not exist in the browser. Cooking must
  be able to run ahead of time so the web target consumes only cooked data.
- **Pool sizing.** Fixed bounds are correct but must be measured. Budgets are
  asserted in the harness so a bound is changed deliberately, with evidence.
- **Sanitizer blind spot.** wgpu-native is prebuilt, so ASan covers the Odin
  side only. `INGOT_GPU_STRICT` remains the compensating control.

## Acceptance

The pipeline is complete for the purposes of this plan when a cooked scene
loads, becomes resident, and renders through the explicit GPU 3D path, while
`fuzz/run.sh asset`, `scene`, `assetio`, `all`, and `gfx-frame` run clean with
recorded seeds, every budget assertion holds, and no stage outside
`scene_gfx` imports `ingot:gfx`.

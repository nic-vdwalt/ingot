# ingot:gfx — WebGPU renderer modernization (reviewed v2)

> Destination when approved: `ingot/docs/rendering.md`.
>
> Status: **reviewed plan only — not implemented**.
>
> This supersedes the first draft. The review found correctness problems in the
> original persistent-buffer, dynamic-uniform, indexed-batch, depth-pass, API
> aliasing, and verification proposals. Those designs must not be implemented as
> originally written.

## Review verdict

The direction is sound, but the original plan is **not safe to implement
verbatim**.

### Critical corrections

1. A persistent vertex buffer cannot be overwritten at offset 0 on every flush.
   Draws are encoded before `QueueSubmit` (`gfx/context.odin:287-300`), so all
   encoded draws could observe the last write. Every encoded run needs an
   immutable range until its submission retires.
2. Dynamic uniform offsets do not make overwritten uniform data immutable. Each
   differing projection/shader state needs a unique aligned record until its
   submission retires.
3. A static quad index stream cannot be mixed with the current arbitrary triangle
   and six-vertex quad stream in one draw. If indexing is introduced, all batch
   primitives and custom-shader draws must use a universal indexed stream, or the
   renderer must split geometry modes.
4. Depth attachments are fixed when a render pass begins. `BeginMode3D` cannot add
   depth to the already-open color-only pass (`gfx/context.odin:259-285`,
   `gfx/camera.odin:51-69`). A real 3D path needs an explicit depth-capable pass
   selected before pass creation, or a separate pass.
5. `Rect` cannot replace `Rectangle` if it changes `.width/.height` to `.w/.h`.
   Existing ingot UI and downstream code rely on the old field names and layout.
6. The current macOS surface setup already prefers `.Premultiplied` before
   `.Unpremultiplied` (`gfx/context.odin:174-185`). The original alpha step partly
   proposed work that already exists; fallback behavior must be measured first.
7. There is no graphics snapshot suite. `testx.snap` is only an inline string
   helper and currently has no graphics users (`testx/snapshot.odin:8-25`).

## Goals

- Keep ingot in Odin and preserve native/web source parity.
- Remove unsafe/per-flush GPU allocation only with correct submission lifetime
  handling.
- Preserve draw ordering, render-target load behavior, public `rlgl` signatures,
  and public type layouts.
- Add real GPU 3D as a new explicit path; do not silently change the legacy
  `BeginMode3D` behavior used by openalloy.
- Keep the existing render-target orientation by default.
- Add an idiomatic additive API without deprecating or moving the current API yet.
- Establish renderer-specific verification before relying on visual claims.

## Non-goals for the first rollout

- Removing the raylib-shaped API.
- Renaming or changing fields in `Vector2`, `Rectangle`, `Color`, `Mesh`,
  `Texture`, or `RenderTexture`.
- Changing the default render-target origin.
- Automatically attaching depth to existing `BeginTextureMode` or
  `BeginMode3D` calls.
- Reworking openalloy's galaxy shaders or bloom chain inside the ingot repository.
- Adding render bundles before profiling demonstrates stable, reusable command
  sequences. Immediate-mode UI with changing vertices is usually a poor initial
  render-bundle target.

## Compatibility contract

The following remain source- and behavior-compatible throughout the rollout:

- Existing PascalCase procedures and all `ingot:gfx/rlgl` signatures.
- `Vector2`, `Vector3`, `Vector4`, `Color`, `Rectangle`, `Texture`, `Font`,
  `RenderTexture`, `Mesh`, and related public field layouts.
- Render-target preserve-by-default behavior. `BeginTextureMode` does not clear;
  `ClearBackground` explicitly selects clear. The nvim dirty-row renderer and
  galaxy accumulation depend on this (`gfx/context.odin:35-40`).
- Current RT orientation (`p.z = -1`) and negative-source-height consumer
  convention.
- Existing legacy 3D path unless a caller opts into the new GPU 3D pass.

Downstream status:

| Consumer | Contract needed |
|---|---|
| `cc-predev-scout` | PascalCase 2D + limited 2D `rlgl` remain unchanged |
| `ww-concord` | PascalCase 2D remains unchanged |
| `openalloy` | All above, plus frozen `rlgl` signatures, `RenderTexture`/`Mesh` layouts, RT preserve/orientation, and opt-in depth |

## Phase 0 — Baseline, instrumentation, and renderer fixtures

Optimization should follow measurements rather than assumptions.

### Files

- `gfx/stats.odin` (new)
- `gfx/render_test_fixture.odin` or a separate `examples/render_fixture/` app
- `docs/rendering.md`

### Work

Add bounded debug counters, disabled in release builds unless configured:

- flush count;
- vertices and indices uploaded;
- bytes uploaded;
- GPU buffer creations/growths;
- pipeline switches;
- bind-group switches;
- render-pass count;
- queue submissions;
- peak per-submission geometry/uniform arena usage.

Create a deterministic fixture at fixed window/target dimensions covering:

1. solid, text, and image batches;
2. interleaved quads and triangles;
3. texture/pipeline/scissor/blend changes that force multiple flushes;
4. main-pass drawing before and after an immediate RT submission;
5. preserve-vs-clear render-target behavior;
6. negative-height render-target blit orientation;
7. two RT ping-pong passes;
8. custom shader uniforms changed between draws;
9. raw `rlgl` instanced drawing;
10. overlapping near/far geometry for the future opt-in 3D path.

The fixture is initially a manual visual/runtime-validation tool. A later GPU
readback harness may add checked-in image baselines, row-pitch normalization, and
explicit tolerance. Do not call this a snapshot suite until that exists.

### Acceptance

- Baseline stats and screenshots/observations are recorded before changing the
  renderer.
- The fixture runs without uncaptured WebGPU errors on native Metal.
- The fixture builds for WASM even if browser inspection remains manual.

## Phase 1 — Submission-safe streamed geometry

### Problem

`renderer_flush` creates one immutable GPU vertex buffer per run
(`gfx/batch.odin:445-470`) and retires those buffers next frame
(`gfx/batch.odin:317-319,343-346`). This is allocation-heavy but preserves each
encoded draw's data.

The original replacement—one buffer repeatedly written at offset 0—is invalid.
`QueueWriteBuffer` writes are not per-draw snapshots, while the main command buffer
is submitted only in `EndDrawing` (`gfx/context.odin:287-300`). Render-target
command buffers may also be submitted while an earlier main pass remains encoded
(`gfx/render_target.odin:41-53,98-126`).

### Design

Introduce a **submission-aware geometry arena**:

```odin
Geometry_Chunk :: struct {
	buffer:   wg.Buffer,
	capacity: u64,
	cursor:   u64,
}

Submission_Resources :: struct {
	chunks:          [MAX_GEOMETRY_CHUNKS]Geometry_Chunk,
	chunk_count:     u32,
	active_chunk:    u32,
	retirement_id:   u64,
	in_flight:       bool,
}
```

Rules:

- Every flush reserves a unique aligned range and writes only that range.
- `SetVertexBuffer` uses the reserved offset and exact size.
- A chunk that has already been referenced by an encoded draw is never replaced
  or released during that submission.
- If a chunk is full, allocate/select another bounded chunk; do not replace the
  active buffer under already encoded commands.
- Associate chunks with the queue submission that references them.
- Recycle only after `QueueOnSubmittedWorkDone` (or the exact callback available
  in the bundled `vendor:wgpu`) reports completion. If that API cannot be used
  reliably on both native and JS, use a conservative bounded frame ring and prove
  its safety against the backend before implementation; never assume N frames is
  sufficient without a completion guarantee.
- Put explicit limits on chunk count and total bytes, with assertions and a
  handled overflow path, per `AGENTS.md:43-65`.
- Keep the current per-flush buffers as a fallback until the arena passes the
  fixture and consumer tests.

A simpler acceptable implementation is one CPU command/geometry stream per
encoder, uploaded once before that encoder is submitted, followed by encoding its
recorded draw records. That requires deferring render-pass draw encoding and is a
larger refactor, but it naturally creates immutable offsets.

### Affected files

- `gfx/batch.odin`
- `gfx/context.odin`
- `gfx/render_target.odin`
- `gfx/shader.odin` (accept vertex offset/range rather than a per-flush buffer)

### Acceptance

- A fixture frame with at least three differently colored runs renders all colors,
  proving earlier runs are not overwritten by the last upload.
- Main-pass → RT submission → main-pass ordering remains correct.
- No per-flush `DeviceCreateBufferWithData` remains in the batch path.
- Buffer growth is bounded and does not release referenced buffers.
- Stats show buffer creation tied to growth/chunks, not flush count.

## Phase 2 — Correct state/uniform lifetime; defer needless consolidation

### Review correction

The two projection buffers are currently deliberate: the RT projection must not
clobber the unsubmitted window projection (`gfx/batch.odin:51-58`). Combining them
is not inherently a best practice and has no demonstrated performance benefit.
Keep `ubuf` and `rt_ubuf` initially.

More importantly, existing custom-shader paths can overwrite one uniform buffer
multiple times before submission:

- `_shader_flush` writes `e.ubuf` at offset 0 (`gfx/shader.odin:418-435`);
- `RlDrawVertexArrayInstanced` does the same (`gfx/rlgl_vao.odin:265-290`).

If shader values differ between encoded draws in one unsubmitted pass, earlier
draws may observe the final values.

### Design

- Add an immutable, aligned **uniform arena per submission**, using the same
  retirement model as Phase 1.
- Query/store the adapter/device minimum uniform-buffer offset alignment; do not
  hard-code 256 without validating the actual limit.
- Allocate one record for each changed custom-shader uniform state and bind it via
  a dynamic offset.
- Preserve projection `ubuf`/`rt_ubuf` until profiling proves consolidation is
  useful. If later consolidated, window and every RT projection get unique arena
  records and the bind group is recreated when its backing buffer changes.
- Include extra texture/sampler bind-group lifetime in the audit; do not rebuild or
  release a bind group while encoded commands still reference it.
- Skip proven no-op state changes, such as zero translation, only after assertions
  preserve ordering invariants.

### Acceptance

- Fixture draws using one shader with different uniforms retain distinct values.
- Raw instanced draws with different uniform values retain distinct values.
- No dynamic offset violates device alignment.
- No bind group references a replaced/released backing buffer.
- Existing window + differently sized RT projections render correctly in one frame.

## Phase 3 — Universal indexed batching (separate optimization)

Do not combine this with Phase 1. First make non-indexed streaming correct and
measurable.

### Design

Use one universal indexed stream:

- `push_tri`: 3 vertices + 3 indices;
- `push_quad`: 4 vertices + 6 indices;
- `push_quad4`: 4 vertices + 6 indices;
- all indices are relative to the run's base vertex;
- custom-shader batch flushing supports indexed draws too.

Use a submission-safe index arena governed by the same lifetime rules as the
vertex arena. A static repeating quad index buffer is insufficient because runs
can interleave arbitrary triangles and quads.

Keep an internal/config build switch to compare indexed and non-indexed paths, but
avoid leaving two permanently divergent implementations. Remove the losing path
after profiling and visual validation.

### Acceptance

- The mixed primitive fixture renders identically.
- Winding and scissor behavior remain unchanged.
- Vertex upload volume for quad-heavy scenes falls by approximately one third.
- Measured CPU/GPU frame time does not regress; otherwise retain non-indexed
  batching.

## Phase 4 — Render-target orientation and alpha correctness

### Render-target orientation

- Define the existing `p.z = -1` behavior as a named internal convention.
- Do **not** change the default.
- Test preserve/clear behavior and negative-source-height blits.
- Any top-left-origin alternative is a new opt-in target/texture-view mode with
  explicit metadata; it must not require guessing from texture identity.
- Bloom consistency belongs partly to openalloy. Ingot supplies explicit,
  documented orientation; openalloy's multipass chain must migrate separately if
  it chooses a new convention.

### Transparent surfaces

The current configuration already selects `.Premultiplied` first when supported
(`gfx/context.odin:174-185`), matching the batch shader's premultiplied output
(`gfx/batch.odin:235-254`). Therefore:

1. store the selected composite alpha mode in `Context`;
2. expose it to diagnostics/stats;
3. validate actual macOS capabilities and output before changing shaders;
4. if only `.Unpremultiplied` is available, design a separate final-composite
   path (premultiplied intermediate texture → un-premultiply overwrite into the
   surface). Do not change batch blend math globally because offscreen targets
   still rely on premultiplied blending.

### Acceptance

- openalloy's nvim render texture remains upright and incremental redraw remains
  preserved.
- openalloy's existing galaxy composite remains upright.
- Two-pass fixture orientation is independent of pass count.
- Transparent macOS output has no halos with the actually selected alpha mode.

## Phase 5 — Explicit opt-in GPU 3D pass

### Review correction

Do not replace `DrawMesh`/`GenMeshSphere` internals or add depth automatically to
legacy passes. `Mesh` layout and legacy behavior are compatibility surfaces, and
attachments cannot be added after a pass starts.

### New API shape

Introduce a separate explicit API, names illustrative and finalized against Odin
style during implementation:

```odin
Gpu_Mesh :: struct { /* opaque registry handle, public layout deliberately small */ }
Gpu_3D_Target :: struct { /* color + depth target handles */ }
Gpu_3D_Pass :: struct { /* generation-checked active pass token */ }

create_sphere_mesh :: proc(radius: f32, rings, slices: u32) -> (Gpu_Mesh, bool)
begin_gpu_3d :: proc(target: ^Gpu_3D_Target, camera: Camera3D,
                     load: Load_Action) -> (Gpu_3D_Pass, bool)
draw_gpu_mesh :: proc(pass: ^Gpu_3D_Pass, mesh: Gpu_Mesh,
                      transform: Matrix, material: Gpu_Material)
end_gpu_3d :: proc(pass: ^Gpu_3D_Pass)
```

The new pass chooses color and depth attachments before
`CommandEncoderBeginRenderPass`. It owns explicit load/store actions so a caller
can preserve or clear color/depth deliberately. It does not share a render pass
with depthless 2D pipelines.

### Pipeline

- indexed mesh vertex/index buffers;
- per-instance model/color data in a submission-safe arena;
- view/projection uniform record with correct alignment/lifetime;
- `.Depth24Plus`, depth write enabled, compare `.Less` for opaque geometry;
- distinct transparent/additive pipeline with depth test configurable and depth
  writes disabled where required;
- bounded mesh/instance counts and explicit ownership/unload procedures;
- pipeline cache keyed by color format, depth format, sample count, blend state,
  culling, and topology.

Billboards and lines remain on the legacy path initially. Port them only after the
mesh path is correct; soft particles require deliberate depth-texture sampling and
are not equivalent to ordinary alpha billboards.

### Acceptance

- Near geometry occludes far geometry independent of submission order.
- Opaque and additive/depth-read-only behavior are distinct and tested.
- Legacy openalloy galaxy remains unchanged until explicitly migrated.
- New 3D fixture has no validation errors on native Metal and builds for WASM.

## Phase 6 — Additive idiomatic Odin API

### Review correction

Do not move old procedures into `compat.odin`, change old public types, or mark the
whole existing API deprecated yet. `ingot:ui` imports and uses the PascalCase API
pervasively; broad deprecation diagnostics would create repository noise.

Add wrappers over the current stable API:

```odin
Vec2 :: Vector2
Vec3 :: Vector3
RGBA :: Color
Rect :: Rectangle // retains x, y, width, height

Frame :: struct {
	generation: u64,
}

begin_frame :: proc() -> (Frame, bool)
end_frame :: proc(frame: ^Frame)
clear :: proc(frame: ^Frame, color: RGBA)
draw_rect :: proc(frame: ^Frame, rect: Rect, color: RGBA)
draw_line :: proc(frame: ^Frame, start, end: Vec2, thick: f32, color: RGBA)
draw_circle :: proc(frame: ^Frame, center: Vec2, radius: f32, color: RGBA)
draw_texture :: proc(frame: ^Frame, texture: Texture2D, source, dest: Rect,
                     origin: Vec2, rotation: f32, tint: RGBA)
```

`Frame` is not a zero-size cosmetic handle. Its generation is checked against the
active frame so stale/double-ended handles fail assertions in development and are
handled safely in release. New procedures carry the assertions required by
`AGENTS.md:43-65`.

Text needs an explicit decision: current `DrawTextEx` accepts `cstring`
(`gfx/text.odin:221`). Either:

- initially make `draw_text` accept `cstring`; or
- first refactor internal text iteration to accept Odin `string` without unsafe
  temporary NUL assumptions, then provide both forms.

Do not promise `string` until that refactor exists.

Keep every existing PascalCase proc as-is. Deprecation is a later project after
`ingot:ui` and downstream consumers migrate and all build gates stay diagnostic
clean.

### Acceptance

- Existing ingot and all three consumers compile unchanged.
- `Vec2`, `RGBA`, and `Rect` preserve old literals, fields, layout, and parameter
  compatibility.
- Frame generation rejects stale/double-ended use in tests.
- No new deprecation diagnostics.

## Verification and exact commands

Run from `/Users/nicolasvanderwalt_1/Development/git/ingot`:

```sh
bash scripts/test.sh
bash scripts/check.sh
odin build web/demo.odin -file -collection:ingot=.
bash build_web.sh
```

What these prove:

- `scripts/test.sh` runs unit tests for `gfx`, `ui`, `term`, and `prefs`, and
  type-checks `net`/`sys` (`scripts/test.sh:7-15`). It does **not** prove visual
  renderer correctness.
- `scripts/check.sh` runs strict type-check/vet/style checks and `odinfmt -l` when
  available (`scripts/check.sh:10-29`).
- `odin build` compiles the native demo; it does not run it.
- `build_web.sh` builds the JS/WASM target; browser behavior still needs a smoke
  run.

Manual smoke currently supported by the existing demo:

```sh
odin run web/demo.odin -file -collection:ingot=.
```

It covers initialization, moving rectangle/circle, text atlas, mouse input, and
keyboard input (`web/demo.odin:26-73`). It does **not** cover textures, scissor,
RTs, bloom, transparent composition, depth, or instancing; use the Phase 0 fixture
for those.

After each renderer phase, also build affected consumers against the modified
local ingot checkout and run the relevant UI manually:

- openalloy: nvim pane and galaxy/HDR view;
- cc-predev-scout: representative map/massing screens and 2D culling toggles;
- ww-concord: representative 2D UI.

Consumer commands must be taken from each repository's own instructions at
implementation time; do not invent or hard-code them in this plan.

## Revised implementation order

1. Replace `ingot/docs/rendering.md` with this reviewed v2 plan.
2. Add bounded renderer stats and a deterministic renderer fixture.
3. Record baseline native results and run all existing build/check gates.
4. Implement submission retirement/resource lifetime infrastructure.
5. Implement unique-offset non-indexed geometry streaming with fallback.
6. Validate geometry streaming, then remove per-flush batch buffers.
7. Fix custom-shader and raw-instancing uniform overwrite hazards using immutable
   aligned records.
8. Profile; consolidate projection uniforms only if measurements justify it.
9. Add universal indexed batching as a separate measured experiment.
10. Name/document/test the existing RT orientation without changing its default.
11. Record and validate selected surface alpha mode; add fallback composite only
    if a real unsupported-premultiplied case is reproduced.
12. Add the explicit opt-in depth-capable GPU 3D pass and mesh pipeline.
13. Add the generation-checked idiomatic API wrappers without deprecation.
14. Run ingot gates, native/web fixtures, and all three downstream builds/smokes.
15. Update README and mark only completed, measured phases as shipped.

## Ship/rollback policy

Each phase lands independently and keeps the old path available until its fixture,
native/web build, and affected consumer checks pass. Do not land buffer lifetime,
uniform lifetime, indexing, 3D, and API changes in one unreviewable change. If a
phase fails visual or validation checks, retain the preceding proven path rather
than weakening assertions or accepting undefined resource lifetime.

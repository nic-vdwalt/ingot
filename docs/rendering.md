# Rendering

`ingot:gfx` provides a raylib-shaped 2D API backed by WebGPU on native and web
targets. It also exposes an explicit depth-capable GPU 3D path. This document
defines the current ownership, submission, render-target, scheduling, and
validation contracts.

## Context and resource ownership

The PascalCase compatibility API uses `default_context()`. `InitWindow` creates
it and `CloseWindow` destroys it. Explicit `context_init`, `context_begin_frame`,
and `context_close` support independently live native contexts rendered in a
deterministic, interleaved order on one owner thread. Each context owns its
window, renderer, input, timing, statistics, submission tracker, and bounded
texture, font-atlas, shader, VAO/VBO, and GPU-3D pools.

Public resources use opaque context- and generation-checked handles. Zero is
invalid, freed slots can be reused, and a handle from another context, an
unloaded resource, or a previous window lifetime cannot resolve to a replacement
resource. The context lifecycle epoch
also rejects frames, sessions, backend adapters, and asynchronous GPU callbacks
from an earlier window lifetime.

`BeginDrawing`/`EndDrawing`, `BeginTextureMode`/`EndTextureMode`, and
`begin_gpu_3d`/`end_gpu_3d` must be balanced. `CloseWindow` requires no active
frame or GPU-3D pass. A partially initialized window may still be closed safely.

`default_context()` exposes the compatibility owner to `ui_gfx.Session` and its
backend adapter. Explicit frames carry their owner, epoch, and generation and
route drawing through that context. A session captures a context and epoch and
can bind an explicit graphics frame. Direct adapter lifecycle calls are backend
implementation details. Parallel renderer threads remain unsupported; browser
hosting remains one managed canvas per module session.

Audio has a separate lifecycle. Pair `InitAudioDevice` with `CloseAudioDevice`;
`CloseWindow` does not close audio.

## Submission lifetime

WebGPU commands reference resources until their queue submission completes.
Ingot therefore treats geometry and uniforms as immutable for the lifetime of a
submission:

- Every batch flush reserves a unique aligned geometry range.
- Indexed batches use a universal stream for triangles and quads.
- Each changed custom-shader or instancing uniform state gets a unique aligned
  record.
- A buffer or bind group referenced by encoded work is not replaced or released.
- Submission resources are recycled only after completion is observed.
- All arenas and pools have explicit bounds and report exhaustion through
  renderer statistics when those statistics are enabled.

Do not overwrite offset zero between encoded draws or infer safety from a fixed
number of frames in flight. `QueueWriteBuffer` does not create a per-draw
snapshot.

The window and render-target projection records remain separate. This prevents a
render target from overwriting an unsubmitted window projection and is a
correctness boundary, not accidental duplication.

## Batching and ordering

The renderer preserves declaration order across solid, text, image, custom
shader, scissor, blend, and texture changes. Solid and text vertices share one
UI pipeline; a per-vertex mode selects flat color or font-atlas coverage. Solid
geometry preserves the active texture binding, so alternating shapes and text
from one font remain in one ordered batch after the atlas is selected. Font,
image, custom-shader, scissor, blend, and target changes still flush as needed.
Immediate render-target submissions may occur while main-pass work is already
encoded; submission resources keep both paths valid.

The indexed stream stores three vertices and three indices for a triangle, and
four vertices and six indices for a quad. Indices are relative to each run's
base vertex. Public draw behavior and winding remain compatible with the
PascalCase API and `ingot:gfx/rlgl`.

Compile with `-define:INGOT_RENDER_STATS=true` and inspect `renderer_stats()` to
measure flushes, uploaded vertices and indices, bytes, buffer creation, pipeline
and bind-group switches, render passes, submissions, arena peaks, and pool
exhaustion. Use measurements before changing batching policy.

## Render targets

`BeginTextureMode` preserves existing target contents. Call `ClearBackground`
inside the target scope when a clear is required. Incremental and accumulation
renderers depend on this preserve-by-default contract.

Render targets use Ingot's named Y-flipped projection convention. Stored
textures are bottom-left-origin and are displayed upright by using a negative
source height when blitting. Apply the same convention at every pass in a
ping-pong or bloom chain; do not alternate flips based on pass count.

`LoadRenderTextureEx(width, height, format, with_depth)` creates explicit color
formats and optional depth storage. Prefer `.RGBA16Float` for HDR passes that
need blending. A 32-bit float target is not blendable unless the WebGPU device
exposes the optional `float32-blendable` feature; Ingot uses overwrite behavior
for non-blendable formats.

Surface composition prefers premultiplied alpha, matching the batch shader and
offscreen blend model. The selected mode is available through renderer
diagnostics. Do not globally change batch color math to compensate for a
platform that exposes only unpremultiplied surface composition.

## Explicit GPU 3D

Depth attachments are fixed when a render pass begins. The legacy
`BeginMode3D` call cannot add depth to an already-open color-only pass, so real
GPU depth rendering uses the separate opt-in API in `gfx/gpu3d.odin`:

- Create and explicitly unload generation-checked GPU meshes and targets.
- Upload bounded indexed triangle, line, or point geometry with `create_gpu_mesh`.
  Vertices carry position, normal, texture coordinates, and a normalized scalar
  that materials may map between two colors. Oversized, malformed, and out-of-range
  geometry is rejected.
- Create caller-owned unit-cube geometry with `create_cube_mesh` or
  `create_cube_edge_mesh`. Both are centered at the local origin with bounds
  `[-0.5, +0.5]`; model transforms provide the final dimensions. The solid mesh
  has flat outward normals, counter-clockwise triangles, and face-local `[0, 1]`
  UVs. The edge mesh contains the same cube's 12 edges as lines. Both return
  `ok=false` for context, pool, validation, or GPU allocation failures and must be
  released with `destroy_gpu_mesh`.
- Materials may bind a generation-checked `Texture2D`; a zero or stale handle falls
  back to the neutral white texture. `depth_nudge` offsets clip depth uniformly for
  coplanar triangle, line, and point overlays without changing model geometry.
- Pass `.MSAA_4X` to `create_gpu_3d_target` for four-sample color and depth. The
  target’s public texture remains single-sampled and receives the resolved color,
  so existing presentation and texture-material paths remain unchanged. Omitting
  the option preserves single-sample rendering.
- Resize offscreen targets transactionally with `resize_gpu_3d_target`; allocation
  failure leaves the previous valid target intact and preserves its antialiasing
  mode. An MSAA `.Preserve` pass retains its multisample attachments; rendering
  directly into only the resolved texture between passes cannot be loaded back into
  those attachments.
- Begin the pass with `begin_gpu_3d`, selecting color/depth load actions before
  pass creation.
- Call `begin_gpu_3d_pro` when the caller already owns a view-projection matrix.
- Configure the pass light with `set_gpu_3d_light`; the default preserves the
  legacy direction and ambient/diffuse factors.
- Submit one model with `draw_gpu_mesh`, or bounded transform batches with
  `draw_gpu_mesh_instanced` (at most 256 instances per encoded draw; larger slices
  are chunked without heap allocation).
- Build allocation-free culling volumes with `camera_frustum` or
  `frustum_from_matrix`, then use `frustum_contains_point` and
  `frustum_intersects_bounds` before submitting meshes.
- Balance the pass with `end_gpu_3d`.

Explicit GPU 3D passes write their attachment in presentation orientation. Blit a
`Gpu_3D_Target` with a positive source height. The negative-source-height rule
applies to targets rendered through `BeginTextureMode`, whose 2D projection is
intentionally Y-flipped to preserve raylib compatibility.

All Ingot 3D APIs use the right-handed ROS world basis: **+X forward, +Y left,
+Z up** (`+X × +Y = +Z`). Camera vectors, model transforms, mesh positions and
normals, lights, bounds, rays, and scene data use this basis. Importers convert
source data exactly once at the import/cook boundary. Matrix-driven Pro entry
points intentionally trust the supplied matrix and perform no axis conversion.

Native CPU picking is allocation-free and does not require a graphics context,
frame, render target, or GPU pass:

- `screen_to_world_ray` constructs a normalized `Ray_3D` from explicit viewport
  dimensions and a `Camera3D`. Perspective rays begin at the camera position;
  orthographic rays begin at the corresponding point on the camera plane.
- `intersect_plane`, `intersect_sphere`, and `intersect_bounds` return
  `(Ray_Hit, ok)`. A miss is `ok = false`; a hit reports its ROS-world position,
  surface normal, and non-negative world-space distance from the ray origin.
- Rays supplied to intersection procedures must have normalized directions.
  Plane normals are normalized by the query. Invalid or non-finite geometry is
  a programmer error and asserts; parallel rays and ordinary misses are handled.
- A ray originating inside a sphere or bounds reports its first forward exit.
  A ray lying in a plane reports a zero-distance hit.

The initial native surface is camera-driven. There is no matrix-driven
`screen_to_world_ray_pro`; callers that own a custom inverse view-projection
matrix retain responsibility for unprojection until that contract is added.

The opaque pipeline uses indexed mesh buffers, submission-safe uniform records,
`.Depth24Plus`, depth writes, and `.Less` comparison for opaque geometry. Generic
GPU meshes support triangle, line, and point-list topology. The current point path
uses the adapter's one-pixel point primitive; larger point sprites remain a future
extension. Bounded dynamic instancing uses a uniform transform block and chunks at
256 instances per draw. Transparent and additive behavior uses distinct pipeline
state. Billboards and legacy mesh calls retain their existing behavior until a
caller deliberately migrates them.

The GPU 3D API is a visualization escape hatch rather than a scene graph,
material system, asset pipeline, or full game engine.
[The 3D content pipeline plan](3d-content-pipeline-plan.md) describes what those
layers would require, including the renderer-independent package split that
keeps import, cook, visibility, and batching testable without a window.

## Compatibility API

Existing PascalCase procedures, `ingot:gfx/rlgl` signatures, and public layouts
remain compatibility surfaces. In particular, `Vector2`, `Vector3`, `Vector4`,
`Color`, `Rectangle`, `Texture`, `Font`, `RenderTexture`, and `Mesh` retain their
fields and layout.

The additive Odin-style aliases preserve those layouts:

```odin
Vec2 :: Vector2
Vec3 :: Vector3
RGBA :: Color
Rect :: Rectangle
```

The additive frame API returns a context-, epoch-, and generation-checked
`Frame`; stale, cross-context, and double-ended handles are rejected. Explicit
`Context` procedures own window, input, resource, and host integration. Each
context owns an independent renderer while the PascalCase API remains a thin
default-context migration facade. New Ingot-native code uses `Frame` and
`Context`; no deprecation of the documented PascalCase subset is currently
implied.

## Event-driven frame scheduling

Frame pacing and frame strategy are separate policies. `ui_gfx.App` defaults to
`.Fixed`, where `target_fps` controls native sleep pacing. `.Uncapped` disables
that pacing. `.Monitor_Refresh` queries the App's bound context and follows the
refresh rate of the monitor with the largest overlap with its window; moving the
window between monitors updates the target on a later `app_tick`. A positive
`target_fps` is used when native refresh information is unavailable. Browser
hosting remains paced by `requestAnimationFrame` rather than native sleeping.

The default strategy is `.Continuous`. Applications may call
`SetFrameStrategy(.Event_Driven)` or the compatibility alias
`EnableEventWaiting()` to avoid building or submitting frames while idle. The
last swapchain image remains presented.

After activity, a bounded settle burst allows hover and release visuals to
finish. `RequestRedraw()` is thread-safe and schedules an immediate frame;
`RequestRedrawIn(seconds)` schedules a timed frame, with the earliest deadline
winning. Use these calls when background work or animation state changes without
platform input.

Native targets wait for GLFW events with a bounded timeout. Cursor, button,
refresh, focus, iconify, and framebuffer-size callbacks wake the app. Minimized
windows wait without consuming settle frames.

On web, the browser animation-frame loop remains installed, but the bridge skips
the application callback while idle. Input and resize exports mark activity;
hidden tabs are suspended by the browser. `GetFrameTime` is clamped to 0.25
seconds so idle waits and resumed tabs do not feed extreme deltas into animation.

`gfx/idle_test.odin` tests the scheduler, and `examples/idle_demo` demonstrates
input wakeup and timed caret repaint.

## Validation

Run the standard source gates first:

```sh
bash scripts/test.sh
bash scripts/check.sh
bash scripts/check-web.sh
```

These commands test renderer invariants and compile native/web seams, but they do
not prove visual correctness. Run the strict windowed resource-lifecycle harness
after changing resource or submission ownership:

```sh
fuzz/run.sh gfx-frame
```

It interleaves texture and render-target unloads, font-atlas resets, UI scaling,
and window resizing under strict WebGPU validation. It requires a working
display and is intentionally excluded from the headless `all` and `soak` fuzz
targets.

The GPU is the one Ingot subsystem where deterministic simulation cannot supply
its own oracle. Resource lifetime errors are not observable from Odin: a stale
view, a resource destroyed while a submission still references it, or a
mismatched binding produces driver-defined behavior rather than a value a
harness can test.
`INGOT_GPU_STRICT` therefore substitutes an external observer, promoting any
WebGPU validation message to an abort, so the generated event ordering that
provoked it still fails under its recorded seed. Generation-checked handles and
fixed pools do the complementary work in-process by making a stale handle a
detectable value instead of a dangling one. Keep new GPU resources inside that
pattern; a resource without a generation check or a declared bound is invisible
to the harness.

Use the deterministic visual and native multi-context fixtures for backend validation:

```sh
odin run examples/render_fixture -collection:ingot=.
odin run examples/multi_context_fixture -collection:ingot=.
bash build_web.sh examples/render_fixture
```

The fixture covers the ergonomic custom-Session lifecycle, mixed batches, state
changes, target preserve/clear behavior, ping-pong orientation, custom uniforms,
and depth-overlapping 3D geometry. Its GPU 3D validation matrix is:

| Fixture | Contract |
|---|---|
| Two overlapping spheres | Depth writes and `.Less` comparison |
| Green sphere behind camera | Clip-space rejection |
| Non-default side light | `set_gpu_3d_light` pass uniforms |
| Textured quad | UV vertex attribute and shared texture bind group |
| Coplanar line and points | Shader `depth_nudge` on non-triangle topologies |
| 300-sphere grid | Instanced draw and 256-instance chunk boundary |

For each release backend, record
operating system, architecture, GPU, driver, backend, browser where applicable,
and date. A successful compile is
`compiled`; only a clean fixture run without validation errors is `validated`.

Current validation status and remaining platform work are maintained in
[Production readiness](production-readiness.md). Testing commands and harness
scope are described in [Testing Ingot](testing.md).

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

Depth attachments are fixed when a render pass begins. `BeginMode3D` therefore
flushes pending 2D work and opens a compatibility-owned depth pass for the cube
helpers and `DrawGrid`. `DrawCubeTransform` and `DrawCubeWiresTransform` accept
complete model matrices for rigid-body or other transformed cubes. `EndMode3D`
composites that transparent pass before later 2D draws. Resources are lazy,
resize with the render size, and are released by `CloseWindow`.

`DrawGrid` is centered on Z=0 in Ingot's XY ground plane. It accepts 1 through
256 slices and caches at most eight slice-count meshes per context; later new
slice counts are skipped once that bound is reached. Cube helpers use ambient-
only lighting so their input colors are preserved, while wires use a depth
nudge to avoid coplanar fighting. Transform helpers provide per-cube model
matrices without making the `rlgl` shim a 3D matrix stack.

For custom geometry, materials, lighting, targets, or passes, use the explicit
GPU 3D API:

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
- Create a caller-owned subdivided plane with `create_plane_mesh`. It is centered
  on the local origin in the XY plane with `+Z` normals, `[0, 1]` UVs, and
  counter-clockwise triangles matching the cube's outward winding. Vertex order
  is row-major, `row * (cells + 1) + column`; `plane_mesh_vertex_count` and
  `plane_mesh_index_count` publish the same arithmetic so an application that
  deforms the surface through `update_gpu_mesh_vertices` can size and check its
  own buffer against the generator rather than re-deriving it. Cell counts are
  bounded by `GPU_3D_PLANE_MAX_CELLS`.
- Materials may bind a generation-checked `Texture2D`; a zero or stale handle falls
  back to the neutral white texture. `depth_nudge` offsets clip depth uniformly for
  coplanar triangle, line, and point overlays without changing model geometry.
- Pass `.MSAA_4X` to `create_gpu_3d_target` for four-sample color and depth. The
  target’s public texture remains single-sampled and receives the resolved color,
  so existing presentation and texture-material paths remain unchanged. Omitting
  the option preserves single-sample rendering.
- Query live target dimensions with `gpu_3d_target_size` instead of reaching
  through the target's resolved render texture. Resize offscreen targets
  transactionally with `resize_gpu_3d_target`; allocation failure leaves the
  previous valid target intact and preserves its antialiasing mode.
  `resize_gpu_3d_target_to_render_size` explicitly synchronizes a target each frame
  and reports `.Unchanged`, `.Resized`, `.Deferred`, or `.Failed`. Deferred sizes
  cover minimized and otherwise non-renderable windows without attempting an
  allocation. An MSAA `.Preserve` pass retains its multisample attachments;
  rendering directly into only the resolved texture between passes cannot be loaded
  back into those attachments.
- Present a completed target with `draw_gpu_3d_target`, providing caller-owned
  destination placement and tint. It derives the full positive-height source
  rectangle from the live target, quietly skips invalid or stale target textures,
  and must not be called while a GPU 3D pass is active.
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

Target-centered cameras use caller-owned `Orbit_Camera_State`, semantic
`Orbit_Camera_Input`, and `Orbit_Camera_Config`. `update_orbit_camera` is a pure
state/input/delta-time step: keyboard rotation and zoom are rates multiplied by
`dt`, while pointer drag and fractional wheel or trackpad scroll are frame deltas.
`orbit_camera_apply` projects the bounded yaw, pitch, and distance back into a
`Camera3D` using Ingot's +Z world-up basis. Applications retain their own key and
pointer bindings rather than coupling camera behavior to the default input context.
`orbit_camera_input_poll` is an optional convenience that samples the default
input context into `Orbit_Camera_Input` under a caller-supplied
`Orbit_Camera_Bindings`; `orbit_camera_bindings_default` returns the
conventional arrow/WASD scheme. It lives in `gfx/camera_input.odin` so
`gfx/camera.odin` stays free of input polling, and it is strictly additive:
`update_orbit_camera` still accepts any `Orbit_Camera_Input`, including one
built from a replay, a network stream, or a test.

Explicit GPU 3D passes write their attachment in presentation orientation.
`draw_gpu_3d_target` preserves that orientation with a positive source height. The
negative-source-height rule applies to targets rendered through `BeginTextureMode`,
whose 2D projection is intentionally Y-flipped to preserve raylib compatibility.

All Ingot 3D APIs use the right-handed ROS world basis: **+X forward, +Y left,
+Z up** (`+X × +Y = +Z`). Camera vectors, model transforms, mesh positions and
normals, lights, bounds, rays, and scene data use this basis. Importers convert
source data exactly once at the import/cook boundary. Matrix-driven Pro entry
points intentionally trust the supplied matrix and perform no axis conversion.

`CAMERA_WORLD_FORWARD`, `CAMERA_WORLD_LEFT`, `CAMERA_WORLD_UP`, and
`CAMERA_WORLD_RIGHT` encode the basis, and
`camera_world_axes_are_right_handed` holds the identity over all four: a
swapped pair reads correctly at every use site and would otherwise surface only
as mirrored geometry.

A geographic application maps its own axis names onto this basis rather than
redefining it. **East/north/up is the same basis** — `forward` is east and
`left` is north, because `east × north = up`. Heading measured clockwise from
north is therefore *not* the orbit camera's `yaw`, which is counter-clockwise
from +X; convert once at the application boundary rather than per call site.

Orbit `yaw` is the azimuth of the camera's offset *from* the target
(`atan2(offset.y, offset.x)`), not the direction the camera looks. Yaw 0 places
the camera on the target's +X side looking back along −X, and positive yaw turns
counter-clockwise seen from +Z.

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
platform input. Generic UI transitions request immediate redraw only while their
caller-owned state is unsettled and snap without another deadline under reduced
motion. Raised paint is buffered in bounded exact `Z_Order` groups and replayed
stably; equal depths retain declaration order while main paint remains streamable.

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

# ingot:gfx — Best-practice WebGPU renderer + API modernization

> Status: **PLAN (not yet implemented).** This document is the agreed design for
> modernizing how `ingot:gfx` uses `vendor:wgpu`, plus an additive idiomatic-Odin
> API. It also records a consumer-compatibility analysis (see
> [Consumer compatibility](#consumer-compatibility)) that gates how some
> workstreams may safely land.

## Overview

Keep ingot in **Odin**. Modernize how `ingot:gfx` uses `vendor:wgpu` so the
renderer follows current WebGPU best practice, and (separately) evolve the public
API away from raylib name-mimicry toward idiomatic Odin (`Rect`, `Vec2`,
`draw_text`, an explicit `Canvas`/`Frame` handle). Five independent workstreams,
native-first, each shippable on its own:

1. **Buffers** — replace per-flush `DeviceCreateBufferWithData` with a persistent,
   growing vertex+index buffer written via `QueueWriteBuffer`; quads become
   4 verts + shared index buffer.
2. **Uniforms & bind groups** — collapse `ubuf`/`rt_ubuf` into one uniform buffer
   with dynamic offsets; cut needless flush triggers.
3. **Real GPU 3D** — depth-tested, instanced mesh pipeline replacing the
   CPU-projected billboard/disc approximation in `render3d.odin`.
4. **Render-target correctness** — fix Y-flip across the multi-pass bloom chain and
   macOS premultiplied transparent-window blending.
5. **API modernization** — an idiomatic Odin façade (`Canvas`, `Rect`, `Vec2`,
   `draw_*`) layered over the same renderer, with raylib names kept as a thin
   deprecated shim for migration.

Workstreams 1–4 are internal (no call-site churn). Workstream 5 is additive and
gated behind a shim so existing consumers keep compiling.

## Approach Discussion

**Why persistent buffers + index buffers (WS1).** `renderer_flush`
(`gfx/batch.odin:445-470`) currently calls `wg.DeviceCreateBufferWithData` on
*every* flush and defers release to next frame via `frame_buffers`
(`batch.odin:82,317-319,343-346`). A UI-heavy frame flushes on every
pipeline/texture/scissor/matrix/blend change, so this allocates and frees dozens
of GPU buffers per frame — the single biggest deviation from WebGPU best practice.
A persistent buffer + `QueueWriteBuffer` with a grow-on-demand policy removes all
per-frame allocation. `push_quad` (`batch.odin:379-394`) emits 6 verts per quad;
switching to 4 verts + a static index buffer cuts vertex bandwidth by a third for
the common case.
  - *Rejected: ring of mapped staging buffers.* Lower latency but much more
    complex (fences, `MapAsync`), and `QueueWriteBuffer` already double-buffers
    internally in wgpu-native. Revisit only if profiling shows a stall.
  - *Rejected: one giant buffer sized to worst case.* Wastes memory and still
    needs a grow path; grow-on-demand is strictly better.

**Why one uniform + dynamic offsets (WS2).** The window pass and each render
target keep *separate* uniform buffers/bind groups (`ubuf`/`ubind` vs
`rt_ubuf`/`rt_ubind`, `batch.odin:46-58,275-289`; swapped in
`render_target.odin:65-66`). A single uniform buffer addressed by dynamic offset
is the idiomatic way to switch projections without a second bind group, and scales
to nested/multiple targets (needed by the bloom chain). Also audit flush triggers
(`batch_set` `batch.odin:368-375`, matrix ops `batch.odin:429-443`) to skip
no-op flushes (e.g. `MatrixModeTranslate` by zero).
  - *Rejected: push constants.* Not in the WebGPU core spec / `vendor:wgpu`.

**Why a real 3D pipeline (WS3).** `render3d.odin` fakes 3D by projecting on the
CPU and drawing discs/quads — no depth test, meshes are discs
(`render3d.odin:1-11,35-50`). The RT pass deliberately attaches **no depth**
(`render_target.odin:90-93`). A proper solution adds a depth-stencil texture, a 3D
vertex layout, and instanced `DrawIndexedInstanced`, matching the roadmap's "true
GPU 3D mesh pipeline" and "indexed instancing" items (README:274-282).
  - *Rejected: keep CPU projection.* Cannot depth-sort transparent node bodies;
    already flagged as a roadmap gap.

**Why fix RT/bloom now (WS4).** Y-flip lives in the uniform (`p.z = -1`,
`render_target.odin:63-66`, shader `batch.odin:215,228-229`). Multi-pass bloom
ping-pongs targets; each blit can re-flip, so parity must be defined once. macOS
transparent windows want premultiplied output reconciled with the surface's
`Unpremultiplied` alpha mode (README:278-281). Both are "Now" roadmap items and
block on-device 3D validation.

**Why an additive API façade (WS5).** The raylib shape assumes hidden global state
(`BeginDrawing`/`EndDrawing` mutate the package global `g`, `context.odin`). We
keep that engine, but add an explicit-handle façade so new code reads idiomatically
and the borrow-free global is an implementation detail. Old names stay as a
`@(deprecated)` shim so no consumer breaks.
  - *Rejected: hard rename.* Breaks every downstream call site at once; the README
    sells mechanical raylib migration, so we preserve it during transition.

## Files Changed

### Workstream 1 — Buffers

**`gfx/batch.odin`** — persistent vertex+index buffers; grow-on-demand; index
buffer for quads.

```diff
 Renderer :: struct {
 	shader: wg.ShaderModule,
 	pipes:  [Pipe_Kind][Blend_Slot]wg.RenderPipeline,
@@
-	// transient per-frame vertex buffers (released at next frame begin)
-	frame_buffers: [dynamic]wg.Buffer,
+	// persistent GPU geometry buffers, grown on demand
+	vbuf:      wg.Buffer,      // usage {.Vertex, .CopyDst}
+	vbuf_cap:  u64,            // bytes
+	ibuf:      wg.Buffer,      // static quad indices {.Index, .CopyDst}
+	ibuf_quads: u32,           // number of quads the index buffer covers
+	// CPU staging for indexed draws
+	indices:   [dynamic]u32,

 	proj_w, proj_h: i32,
 }
```

```diff
 renderer_flush :: proc(r: ^Renderer, pass: wg.RenderPassEncoder) {
 	n := len(r.verts)
 	if n == 0 do return
-
-	vbuf := wg.DeviceCreateBufferWithData(g.device, &{usage = {.Vertex}}, r.verts[:])
-	append(&r.frame_buffers, vbuf)
+	// ensure the persistent vertex buffer is large enough, then upload
+	need := u64(n) * size_of(Vertex)
+	_ensure_vbuf(r, need)
+	wg.QueueWriteBuffer(g.queue, r.vbuf, 0, raw_data(r.verts), int(need))
@@
-	wg.RenderPassEncoderSetVertexBuffer(pass, 0, vbuf, 0, u64(n * size_of(Vertex)))
-	wg.RenderPassEncoderDraw(pass, u32(n), 1, 0, 0)
+	wg.RenderPassEncoderSetVertexBuffer(pass, 0, r.vbuf, 0, need)
+	wg.RenderPassEncoderDraw(pass, u32(n), 1, 0, 0)

 	clear(&r.verts)
 }
```

New helper `_ensure_vbuf(r, need)`: if `need > r.vbuf_cap`, release old buffer and
create a new one at `next_pow2(need)`; update `vbuf_cap`. `renderer_frame_begin`
(`batch.odin:343-362`) drops the `frame_buffers` release loop. `renderer_shutdown`
(`batch.odin:317-341`) releases `vbuf`/`ibuf` instead of `frame_buffers`.

*Phase 1b (optional, same file):* switch `push_quad` to append 4 verts + 6 indices
into `r.indices`, build a static quad index buffer once, and use
`RenderPassEncoderSetIndexBuffer`/`DrawIndexed`. Keep `push_tri` on the non-indexed
path or emit a degenerate index run. Gate behind a `USE_INDEXED :: true` const so
it can be toggled if a regression appears.

### Workstream 2 — Uniforms & bind groups

**`gfx/batch.odin`** — one uniform buffer, dynamic-offset bind group.

```diff
-	ubuf:         wg.Buffer,
-	ubind:        wg.BindGroup,
 	ubind_layout: wg.BindGroupLayout,
 	tex_layout:   wg.BindGroupLayout,
-	rt_ubuf:  wg.Buffer,
-	rt_ubind: wg.BindGroup,
-	cur_u:    wg.BindGroup,
+	ubuf:     wg.Buffer,       // holds N projection slots, 256-byte aligned
+	ubind:    wg.BindGroup,    // single dynamic-offset bind group
+	u_slots:  u32,             // allocated projection slots
+	cur_off:  u32,             // dynamic offset (bytes) for the next flush
```

- Bind-group layout entry gains `hasDynamicOffset = true`; `minBindingSize` stays
  `size_of([4]f32)` (`batch.odin:267-274`).
- `renderer_flush` `SetBindGroup(pass, 0, r.ubind, {r.cur_off})` (dynamic offsets
  array).
- Window projection = slot 0; each `BeginTextureMode` writes its y-flipped
  projection into the target's slot and sets `cur_off`; `EndTextureMode` resets
  `cur_off = 0` (replaces the `cur_u` swap in `render_target.odin:65-66,102,122`).
- Flush-trigger audit: `MatrixModeTranslate` (`batch.odin:439-443`) returns early
  when `x==0 && y==0`; `batch_set` (`batch.odin:368-375`) already guards on change.

### Workstream 3 — Real GPU 3D

**`gfx/render3d.odin`** — replace CPU projection internals with GPU mesh submission
(public proc names/signatures unchanged so call sites are stable). `GenMeshSphere`
generates real vertex/index data instead of a marker (`render3d.odin:16-25`);
`DrawMesh` records an instance (transform + color) into a per-frame instance buffer
instead of drawing a disc (`render3d.odin:35-50`).

**`gfx/gpu3d_pipeline.odin`** *(new)* — a depth-tested instanced pipeline:
```
Mesh3DVertex :: struct { pos: [3]f32, normal: [3]f32 }
Instance3D   :: struct { model: matrix[4,4]f32, color: [4]f32 }
```
WGSL with `@builtin(position)` from `view_proj * model * pos`, simple lambert
shade; `depthStencil = { format = .Depth24Plus, depthWriteEnabled = true,
depthCompare = .Less }`; instance step-mode buffer via the existing VAO backing
(`gfx/rlgl_vao.odin`). Flushed in `EndMode3D` (`gfx/camera.odin:51-66`).

**`gfx/render_target.odin`** — attach depth in the RT pass for 3D targets. Replace
the "no depth" note (`render_target.odin:90-96`):
```diff
-	desc := wg.RenderPassDescriptor{colorAttachmentCount = 1, colorAttachments = &color}
-	// NOTE: ... intentionally do not attach a depth buffer here ...
+	depth_att: wg.RenderPassDepthStencilAttachment
+	desc := wg.RenderPassDescriptor{colorAttachmentCount = 1, colorAttachments = &color}
+	if g.frame.rt_depth && g.frame.depth_view != nil {
+		depth_att = {
+			view = g.frame.depth_view,
+			depthLoadOp = .Clear, depthStoreOp = .Store, depthClearValue = 1.0,
+		}
+		desc.depthStencilAttachment = &depth_att
+	}
```
Window-pass 3D also needs a depth attachment: add a lazily-created depth texture to
`Frame_State`/`_ensure_pass` (`gfx/context.odin`) used when `mode3d` is active.

### Workstream 4 — Render-target / bloom correctness

**`gfx/render_target.odin`** + **`gfx/batch.odin` shader** — define the y-flip
convention in exactly one place. Document that RT content is stored top-left origin
(`p.z = +1`) and the blit does the visual flip, OR bottom-left (`p.z = -1`) with
straight blits — pick one and make every bloom pass consistent so an even number of
ping-pongs is not required. Add a `RT_FLIP :: ...` const and reference it from
`BeginTextureMode` (`render_target.odin:63-66`) and any blit helper.

**`gfx/context.odin`** (macOS transparent path) — when
`.WINDOW_TRANSPARENT` is set and the surface alpha mode is `Unpremultiplied`, either
configure the surface `alphaMode` to `Premultiplied` if supported, or add an
un-premultiply step in the final composite so semi-transparent backdrops blend
correctly (README:278-281). Guard behind `when ODIN_OS == .Darwin`.

### Workstream 5 — API modernization (additive)

**`gfx/api.odin`** *(new)* — idiomatic Odin façade over the same globals:
```odin
Vec2 :: [2]f32
Rect :: struct { x, y, w, h: f32 }
RGBA :: distinct [4]u8

Canvas :: struct {}   // zero-size handle; methods forward to package globals

begin_frame :: proc() -> Canvas          // == BeginDrawing
end_frame   :: proc(c: Canvas)            // == EndDrawing
clear       :: proc(c: Canvas, col: RGBA) // == ClearBackground
draw_rect   :: proc(c: Canvas, r: Rect, col: RGBA)
draw_text   :: proc(c: Canvas, font: Font, s: string, at: Vec2, size: f32, col: RGBA)
measure_text:: proc(font: Font, s: string, size: f32) -> Vec2
// ... draw_circle, draw_line, draw_texture, key_down, mouse_pos ...
```
Names are snake_case; the `Canvas` param makes frame scoping explicit even though
state is global (threading a handle now lets us move state off the global later
without touching call sites).

**`gfx/compat.odin`** *(new; move existing raylib-named procs here or wrap)* — mark
the raylib-shaped API `@(deprecated="use ingot:gfx draw_* / Canvas API")` thin
wrappers that call the new façade. Keep `Vector2`/`Rectangle`/`Color` as aliases of
`Vec2`/`Rect`/`RGBA` so both spellings resolve during migration.

**`ui/*`** — no change required initially (still calls raylib-named procs via the
shim). A follow-up migrates `ingot:ui` to the `draw_*` façade file-by-file.

## New Dependencies / Config Changes

None. All work stays within `vendor:wgpu` and `core:*`. No new env vars, config
keys, or external libs. A new build-tag-free source file per new `.odin` above.

## Impact & Risks

- **WS1 index buffer** changes vertex winding assumptions — verify
  `frontFace = .CCW, cullMode = .None` (`batch.odin:144`) still produces identical
  output; gate behind `USE_INDEXED` const for quick rollback.
- **WS2 dynamic offsets** require 256-byte alignment of uniform slots; a wrong
  offset silently reads the wrong projection → verify RT + window in the same frame
  (galaxy pane) still render correctly.
- **WS3 depth** interacts with existing 2D batch pipelines, which carry **no**
  depth-stencil state (`batch.odin:141-147`). A pass with a depth attachment
  requires every pipeline used in it to declare matching depth-stencil state.
  Mitigation: keep 2D and 3D in separate passes/targets, or give 2D pipelines a
  `depthWriteEnabled = false, depthCompare = .Always` state when a depth attachment
  is present. This is the highest-risk item — do it last.
- **WS4** wrong flip fix can invert all RT output; snapshot-test before/after.
- **WS5** deprecation warnings will appear across `ingot:ui`; acceptable during
  transition, silence per-file as `ui` migrates.
- Backwards compatibility: WS1–4 are internal; WS5 is additive with a shim, so no
  external call site breaks — **but see the consumer analysis below: WS3 and WS4
  touch behavior that `openalloy` depends on.**

## Consumer compatibility

Three downstream consumers were audited for how they use `ingot:gfx`. Summary:

| Consumer | ingot:gfx usage | WS1 | WS2 | WS3 | WS4 | WS5 |
|---|---|---|---|---|---|---|
| **cc-predev-scout** | pure 2D, ~218 `rl.*`, 4 `rlgl` 2D-batch calls, no RT/3D/shaders | safe | safe | n/a | safe | safe* |
| **ww-concord** | pure 2D, ~123 `rl.*`, no rlgl/3D/RT | safe | safe | n/a | safe | safe* |
| **openalloy** | 2D + **nvim render-texture pane** + full HDR/bloom/galaxy 3D, heavy `rlgl.*` | safe† | safe† | ⚠ **breaks galaxy** | ⚠ **breaks nvim pane + galaxy** | safe* |

\* WS5 is safe for all **only if** the raylib PascalCase names are kept as working
shims (never removed). Deprecation warnings are fine; no consumer builds with
`-warnings-as-errors`.

† Safe **only if** the public `rlgl.*` signatures and the `RenderTexture` struct
field layout (`.texture.id`, `.depth.id`, `.width`, `.height`) are preserved.
openalloy writes those fields by hand and calls `rlgl.LoadFramebuffer` /
`LoadVertexBuffer` / `DrawVertexArrayInstanced` directly.

### Where openalloy is affected

- **WS4 (Y-flip) — not galaxy-only.** The everyday **Neovim editor pane** caches
  its grid to a render texture and blits it with a Y-flip-compensating negative
  source height:
  - `alloy/src/ui/nvim_render.odin:310` — `LoadRenderTexture`
  - `alloy/src/ui/nvim_render.odin:455` — `src := rl.Rectangle{0, 0, w, -h}`
  Changing the default RT convention makes the **editor render upside-down**. The
  galaxy view has the same pattern at `alloy/src/ui/galaxy_shaders.odin:403`.
- **WS3 (depth) — galaxy only.** The galaxy already runs its own depth strategy: a
  hand-built HDR framebuffer with a depth renderbuffer
  (`galaxy_shaders.odin:29-39`), a depth prepass (`galaxy3d.odin:406-414`), and
  explicit `rlgl.DisableDepthMask`/`EnableDepthMask` around the additive pass
  (`galaxy3d.odin:441,540`). If `BeginMode3D`/`BeginTextureMode` start
  auto-attaching/clearing depth, it double-ups and the "cardboard panel" artifact
  it works around (`galaxy3d.odin:432-440`) likely returns.
- Files reaching into these internals: `nvim_render.odin`, `galaxy_shaders.odin`,
  `galaxy_planet.odin`, `galaxy_instanced_stars.odin`, `galaxy_instanced_2d.odin`,
  `galaxy3d.odin`.

### Recommended guardrails (make the plan fully non-breaking)

1. **WS4 — do not change the default.** Keep the existing `p.z = -1` RT convention.
   Only *document* it in one place (`RT_FLIP` const referencing today's value). Any
   new convention must be opt-in via a new proc, never a change to the value
   consumers compensate for. Protects both the nvim pane and galaxy.
2. **WS3 — depth is opt-in, off by default.** Only attach/clear depth when a new
   flag/param requests it. `BeginMode3D`/`BeginTextureMode` keep today's no-depth
   behavior unless asked, so openalloy's manual depth path is untouched.
3. **WS1/WS2 — freeze the public surface.** Change internals freely, but keep every
   `rlgl.*` signature and every `RenderTexture` field openalloy touches identical.

With these guardrails, all three consumers compile and render unchanged, and the
improvements land internally + via new opt-in APIs.

### Suggested phasing given the analysis

- **Non-breaking now:** WS1 (buffers), WS2 (uniforms), WS5 (API façade) — safe for
  every consumer with the shim + frozen-surface guardrails.
- **Gated / opt-in:** WS3 (depth) and WS4 (Y-flip) — implement behind the guardrails
  above, or defer until openalloy's nvim pane + galaxy path migrate in lockstep.

## Verification Steps

1. Build native: `odin build web/demo.odin -file -collection:ingot=.` (or the
   project's existing native build command) — expect no compile/validation errors.
2. Run the existing headless test(s): `bash scripts/test.sh` (covers
   `text_test.odin`, wrap/markdown/scale tests). Expect all pass.
3. `testx` snapshot tests: run the snapshot suite and diff `Snapshot` outputs for
   the batch/text paths; regenerate goldens only for intended visual changes.
4. Visual smoke (native macOS/Metal): launch the demo; confirm 2D shapes, text,
   textures, scissor, and a render-target blit render identically to `main`.
5. WS3: render a depth-tested sphere/instanced meshes; confirm correct occlusion
   (near hides far) — the current disc approximation cannot do this.
6. WS4: verify RT content is upright through a 2+ pass bloom ping-pong (no
   parity-dependent flip); on macOS verify a semi-transparent backdrop composites
   without haloing.
7. Frame-allocation check: confirm no `DeviceCreateBufferWithData` per flush
   (grep the flush path) and that `frame_buffers` is gone.
8. **Consumer regression:** build `openalloy` against the modified ingot and
   verify the nvim editor pane renders upright and the galaxy/HDR view is unchanged
   (this is the canary for WS3/WS4).

## Implementation Steps

1. Copy this plan to docs/rendering.md
2. WS1: add persistent vbuf + _ensure_vbuf, rewrite renderer_flush
3. WS1: remove frame_buffers from init/frame_begin/shutdown
4. WS1: add quad index buffer behind USE_INDEXED and switch push_quad
5. WS2: collapse ubuf/rt_ubuf into one dynamic-offset uniform buffer
6. WS2: update BeginTextureMode/EndTextureMode to use dynamic offsets
7. WS2: prune no-op flush triggers (MatrixModeTranslate zero, etc.)
8. WS4: define single RT_FLIP convention; make bloom passes consistent
   *(guardrail: keep today's default value; new conventions opt-in only)*
9. WS4: fix macOS premultiplied transparent-window compositing
10. WS3: add gpu3d_pipeline.odin (depth-tested instanced mesh pipeline)
11. WS3: real GenMeshSphere geometry + DrawMesh instance recording
12. WS3: attach depth in RT pass and window pass for 3D mode
    *(guardrail: depth opt-in / off by default)*
13. WS3: reconcile 2D pipelines with depth attachment (depthCompare Always)
14. WS5: add gfx/api.odin idiomatic façade (Canvas/Rect/Vec2/draw_*)
15. WS5: add gfx/compat.odin deprecated raylib-name shim + type aliases
    *(guardrail: never remove PascalCase names; freeze rlgl + RenderTexture layout)*
16. Run scripts/test.sh + snapshot suite; visual smoke on native; build openalloy
17. Update README rendering section + docs/rendering.md status

# Migrating from raylib

## Supported migration profile

Ingot provides targeted source compatibility for common 2D Odin applications,
not a complete implementation of raylib, raymath, raylib 3D, shaders, or `rlgl`.
The best candidates use the window and frame lifecycle, 2D shapes, textures,
render textures, fonts, `Camera2D`, keyboard/mouse input, and basic audio or
gamepad input. Applications built around models, animation, GLSL, raw OpenGL
state, CPU image processing, or low-level `rlgl` rendering require a manual
WebGPU port.

Compatibility covers the documented PascalCase procedures and public layouts in
`ingot:gfx` at a pinned Ingot revision. Internal registries, private procedures,
and undocumented bridge behavior are not stable APIs. A successful compile
proves source compatibility only; it does not prove visual, timing, input,
audio, browser, or GPU-backend equivalence.

Ingot does not ship a graphics procedure that renders nothing. Anything this
renderer cannot honour is absent, so the compile errors you get during a
migration are the accurate inventory of what needs porting. See
[what compiles is what works](compatibility.md#what-compiles-is-what-works) and
the [closed non-goal list](compatibility.md#not-implemented-and-not-planned).

`examples/raylib_migration_fixture` continuously checks the documented
import-only 2D surface. [Breakout](../examples/breakout/main.odin) is the larger
native-and-web example. [Rendering](rendering.md) documents renderer ownership,
render-target conventions, and Ingot's explicit GPU 3D path.

## Before you migrate

Pin all three inputs in source control and CI:

- The source application's working raylib and Odin revisions.
- The Ingot Git revision being evaluated.
- Odin `dev-2026-06:285f6d87b`, which is the revision currently tested by Ingot.

Record a native visual baseline before changing imports. Include representative
input, HiDPI, render-target, shader, audio, and gamepad behavior. If the
application has a web target, record the browser, operating system, GPU, and
asset hosting layout as well.

Inventory imports and calls by subsystem. Any direct `vendor:raylib/rlgl`, GLSL,
model, mesh, material, skeletal animation, image-processing, gesture, touch, or
advanced audio use should be treated as a porting task rather than assumed to be
covered by the import-only path.

## Minimal import and build conversion

Register Ingot as an Odin collection:

```sh
odin check src -collection:ingot=libs/ingot
odin build src -collection:ingot=libs/ingot
```

Change the package imports first, without changing application behavior:

```odin
// Before.
import rl "vendor:raylib"
import rlgl "vendor:raylib/rlgl"

// After.
import rl "ingot:gfx"
import rlgl "ingot:gfx/rlgl"
```

Compile immediately. Classify each error or behavior dependency using the table
below before editing it. Do not make a passing compile the migration finish
line.

## Classification legend

| Classification | Meaning |
|---|---|
| **Import-only** | Replacing the package import should preserve ordinary documented call sites. |
| **Mechanical edit** | A predictable type, signature, lifecycle, ownership, or loading change is required. |
| **Behavior change** | Calls compile, but WebGPU, platform, or browser semantics differ and require validation. |
| **Manual port** | Redesign the feature for Ingot or explicit WebGPU rather than preserving its raylib implementation. |
| **Unsupported** | Ingot has no production implementation for the feature. |

A subsystem may have a safe import-only core and separate behavior-changing or
unsupported operations. Use the strictest classification reached by the calls
your application actually makes.

## Subsystem compatibility matrix

| Subsystem | Classification | Current compatibility and required action | Evidence |
|---|---|---|---|
| Window lifecycle and configuration | **Import-only** core; **behavior change** for platform flags | `SetConfigFlags`, `InitWindow`, `WindowShouldClose`, dimensions, timing, `SetWindowTitle`, `IsWindowResized`, and `CloseWindow` use the default compatibility context. `IsWindowResized` reports a logical size change; a DPI-only change is reported through `GetWindowScaleDPI` instead. HiDPI, transparency, custom chrome, and platform flags require native validation. A browser owns its canvas and page lifecycle: it honours `SetWindowTitle` through the document title, but `SetWindowPosition` cannot move a page and `GetWindowPosition` reports the canvas origin. | [`gfx/context.odin`](../gfx/context.odin), [platform limits](compatibility.md#graphics-and-window-limitations) |
| Frame loop | **Mechanical edit** for native/web shared source | `BeginDrawing`, `ClearBackground`, and `EndDrawing` retain their shape. Prefer `rl.run(frame)` for shared source: it blocks natively and registers a browser animation callback on web. State reached by `frame` must outlive `main` on web. | [`gfx/context.odin`](../gfx/context.odin), [`gfx/loop_web.odin`](../gfx/loop_web.odin), [`gfx/platform_native.odin`](../gfx/platform_native.odin) |
| 2D shapes and scissor | **Import-only** | The documented rectangle, line, triangle, circle, ring, sector, ellipse, polygon, pixel, fan, strip, gradient, and scissor calls feed Ingot's WebGPU batch renderer. Compare antialiasing, edge coverage, and blending visually. | [`gfx/shapes.odin`](../gfx/shapes.odin), [`examples/render_fixture`](../examples/render_fixture/main.odin) |
| Colors and basic math types | **Import-only** core; **unsupported** as full raymath | `Color`, `Vector2`, `Vector3`, `Vector4`, `Rectangle`, camera types, common matrix helpers, and the `Fade`/`ColorAlpha`/`ColorAlphaBlend` helpers are available. `ColorAlphaBlend` reproduces raylib's 8-bit arithmetic exactly, including the one-unit loss per channel that a `WHITE` tint causes. This does not provide the complete raymath package; use `core:math/linalg`. | [`gfx/types.odin`](../gfx/types.odin), [`gfx/colors.odin`](../gfx/colors.odin), [`gfx/camera.odin`](../gfx/camera.odin) |
| Images and textures | **Import-only** for documented loading/drawing; **mechanical edit** for memory loads; **behavior change** for formats and web assets | `Image`, `Texture2D`, file/memory image loading, texture creation, filtering, drawing, and unload calls cover the common path. `LoadImageFromMemory` and `LoadFontFromMemory` take `[^]u8` rather than `rawptr`, so pass `raw_data(bytes)`; the stricter type is deliberate and will not be relaxed. On web, path-based `LoadTexture` does not exist, so calling it is a compile error naming the supported route rather than a texture that silently fails to load. The WebGPU registry owns GPU resources, format support is narrower than the enum list implies, and browser paths are hosted URLs. | [`gfx/types.odin`](../gfx/types.odin), [`gfx/texture.odin`](../gfx/texture.odin) |
| Render textures | **Import-only** core; **behavior change** for orientation and depth | `LoadRenderTexture`, `BeginTextureMode`, `EndTextureMode`, and unload are real WebGPU render targets. Validate source-rectangle Y orientation. Compatibility render targets do not imply arbitrary framebuffer attachment parity. | [`gfx/render_target.odin`](../gfx/render_target.odin), [render-target contract](rendering.md#render-targets) |
| Text and fonts | **Mechanical edit** when code inspects layouts | Custom font loading, `DrawTextEx`, `MeasureTextEx`, `DrawTextPro`, and unload are supported. `DrawText` and `MeasureText` are backed by an embedded default font, so raylib's no-asset text path works and `MeasureText` returns real metrics rather than an estimate; they carry no implicit inter-glyph spacing because the embedded face's own advances already include it. `-define:INGOT_DEFAULT_FONT=false` drops the embedded face, and both procedures then stop existing rather than silently drawing nothing. `Font` exposes only the fields Ingot consumers use, not raylib's complete public layout, and there is no `GlyphInfo`. | [`gfx/types.odin`](../gfx/types.odin), [`gfx/text.odin`](../gfx/text.odin), [`gfx/font_default.odin`](../gfx/font_default.odin) |
| Keyboard, mouse, clipboard, and cursor | **Import-only** core; **behavior change** for platform seams | Documented key/button transitions, character queues, mouse position/delta/wheel, clipboard, and cursor calls are present. `SetMouseOffset` is not implemented, because no backend applied it; remove the call or apply the offset in application code. IME behavior is platform-specific and incomplete on some native platforms. | [`gfx/input.odin`](../gfx/input.odin), [`gfx/ime_other.odin`](../gfx/ime_other.odin) |
| Cameras | **Import-only** for `Camera2D`; **behavior change** for compatibility 3D | `BeginMode2D`/`EndMode2D` apply a `Camera2D` exactly: it is an affine, and the batch already transforms every vertex it emits, so pan, zoom, and rotation are real rather than approximated. `GetCameraMatrix2D`, `GetWorldToScreen2D`, and `GetScreenToWorld2D` are available. A zero-zoom camera has no inverse; `GetScreenToWorld2D` returns the camera target instead of raylib's infinities. Compatibility `BeginMode3D` projects on the CPU into the 2D batch and is not a depth-capable raylib 3D renderer. | [`gfx/types.odin`](../gfx/types.odin), [`gfx/camera.odin`](../gfx/camera.odin), [`gfx/affine.odin`](../gfx/affine.odin) |
| Audio and music | **Import-only** basic calls; **behavior change** on web and for streaming | Device, sound, wave, playback, volume, pitch, and music calls cover the basic API. Browser file loads are asynchronous hosted-URL fetches and may require a user gesture. Poll `IsSoundReady` or `IsMusicReady`. `UpdateMusicStream` intentionally has no effect; native music streams on the device thread while web music is fully decoded. `Sound` and `Music` layouts are not full raylib layouts. | [`gfx/audio.odin`](../gfx/audio.odin), [`gfx/audio_web.odin`](../gfx/audio_web.odin) |
| Gamepads | **Import-only** queries; **behavior change** by host | Availability, names, buttons, transitions, and six standard axes are mapped to raylib-shaped enums. Browser and native controller mappings, connection policy, and device support still require representative hardware tests. | [`gfx/types.odin`](../gfx/types.odin), [`gfx/input.odin`](../gfx/input.odin) |
| Shaders | **Manual port** | Procedure names resemble raylib, but shader source must be WGSL, not GLSL. Ingot expects fixed bind groups, `vs_main`/`fs_main` entry points, a reflected `struct U`, and at most four extra sampled textures. Port shader code and resource bindings explicitly. | [`gfx/shader.odin`](../gfx/shader.odin), [rendering](rendering.md) |
| Blend modes | **Behavior change** | Standard batch modes select WebGPU pipelines with premultiplied inputs. Custom factors are translated from a limited set of GL-style constants. Validate equations and alpha output rather than assuming OpenGL blending equivalence. Depth-mask state is not implemented: `rlgl.EnableDepthMask`/`DisableDepthMask` and `SetDepthMask` recorded a flag that changed nothing and have been removed. | [`gfx/gpu3d.odin`](../gfx/gpu3d.odin), [`gfx/rlgl/rlgl.odin`](../gfx/rlgl/rlgl.odin) |
| 3D, models, meshes, and materials | **Manual port**; **unsupported** for general raylib model/animation APIs | Compatibility lines, billboards, spheres, and meshes are CPU-projected 2D approximations without compatibility-path depth behavior. `DrawMesh` renders a shaded disc and `UnloadMesh` has no work. Use Ingot's explicit depth-capable GPU 3D API for supported mesh work; general model loading, skeletal animation, and raylib material parity are not production features. | [`gfx/camera.odin`](../gfx/camera.odin), [`gfx/render3d.odin`](../gfx/render3d.odin), [`gfx/gpu3d.odin`](../gfx/gpu3d.odin) |
| `rlgl` batch and 2D matrix calls | **Behavior change** | `DrawRenderBatchActive` performs a real batch flush. The matrix shim carries a full 2D affine, so `PushMatrix`/`Translatef`/`PopMatrix` compose correctly with a `Camera2D` and translate along the active transform's axes. It is not an immediate-mode OpenGL layer. | [`gfx/rlgl/rlgl.odin`](../gfx/rlgl/rlgl.odin), [`gfx/affine.odin`](../gfx/affine.odin) |
| `rlgl` vertex arrays and buffers | **Manual port** | Calls retain selected signatures for source compatibility, but the compatibility implementation is limited to an internal instancing path and is not a general immediate-mode renderer. Port low-level drawing to explicit WebGPU or Ingot GPU 3D. | [`gfx/rlgl/rlgl.odin`](../gfx/rlgl/rlgl.odin), [`gfx/rlgl_vao.odin`](../gfx/rlgl_vao.odin) |
| `rlgl` framebuffers and depth state | **Unsupported** | `LoadFramebuffer`, `EnableFramebuffer`, `DisableFramebuffer`, `FramebufferAttach`, and `FramebufferComplete` were bookkeeping-only no-ops that accepted a framebuffer assembly this renderer never performed, and have been removed; calling them is now a compile error. Use `RenderTexture2D` or an explicit GPU target. `LoadTexture`/`LoadTextureDepth`/`UnloadTexture` remain and are backed by real render-target textures. | [`gfx/rlgl/rlgl.odin`](../gfx/rlgl/rlgl.odin), [`gfx/render_target.odin`](../gfx/render_target.odin) |
| Window icons | **Behavior change** | Native hosts may apply icon operations, but the browser owns page icons and window presentation. Treat icon setup as platform packaging, not cross-target rendering state. | [`gfx/platform_native.odin`](../gfx/platform_native.odin), [`gfx/platform_web.odin`](../gfx/platform_web.odin) |
| Touch, gestures, image processing, advanced audio, screenshots, and broad raylib utilities | **Unsupported** unless a specific Ingot procedure is documented | Do not infer support from a related type or enum. [Compatibility](compatibility.md#not-implemented-and-not-planned) carries the closed list of surfaces Ingot will not implement, with the reason for each. Replace these features with application code, another package, or an approved Ingot addition. | [`gfx/api.odin`](../gfx/api.odin), [compatibility policy](compatibility.md#versioning-policy) |

## Staged conversion workflow

### 1. Freeze a known-good baseline

Pin the source application's dependencies, then capture native screenshots or
render fixtures and the exact test commands. Record frame timing separately from
visual output. For web applications, also record the browser, GPU, asset URLs,
and whether audio has been unlocked by a user gesture.

### 2. Replace imports only

Register the Ingot collection and replace the two package paths. Do not port
shaders, alter the frame loop, or rewrite resources in the same change. Compile
the smallest application package first so unresolved names reveal the actual
surface your application uses.

### 3. Classify every failure

Map each unresolved symbol or incompatible layout to the matrix. Preserve calls
classified **Import-only**. Make explicit, reviewable changes for **Mechanical
edit** items. Add runtime checks for **Behavior change** items. Isolate **Manual
port** and **Unsupported** features behind application-owned seams before
continuing.

Do not add compatibility wrappers that silently accept a feature which Ingot
does not render. A compile error is safer than treating a framebuffer, depth,
model, or low-level draw no-op as successful output.

### 4. Establish the shared frame lifecycle

Native-only code may retain its `for !rl.WindowShouldClose()` loop. Code intended
for both native and web should move one iteration into a callback and call
`rl.run(frame)`. On web, `rl.run` returns after installing the animation callback,
so callback state and GPU handles must not point into `main` stack storage.

A managed host must retain the session returned by `ingotWeb.run()`. Destroy that
session before replacing the application, or call `ingotWeb.stop()` during global
page teardown. Only one managed active application session is supported per
page.

### 5. Port resources and assets

Keep image, texture, render-texture, font, sound, music, and window destruction
explicit. Load resources after `InitWindow` or `InitAudioDevice`, check returned
handles or ready queries, and unload them before native shutdown. Web file names
are hosted URLs relative to the page rather than native filesystem paths.

File-backed browser audio resolves asynchronously. Poll `IsSoundReady` and
`IsMusicReady`; do not assume a non-zero handle is immediately audible. Ensure a
user interaction can unlock WebAudio. Validate render-texture Y orientation and
HiDPI logical-versus-render dimensions with the application's actual assets.

### 6. Redesign shaders and advanced rendering

Translate GLSL to WGSL rather than passing the original strings to
`LoadShaderFromMemory`. Conform to Ingot's documented bind groups and entry-point
names, then validate uniform alignment and texture bindings. Replace arbitrary
framebuffer assembly with `RenderTexture2D` or explicit WebGPU targets.

Move model, animation, depth-sensitive, instanced, or raw `rlgl` work to Ingot's
explicit GPU path. The compatibility 3D calls are CPU-projected approximations;
they are suitable only where the approximation itself is acceptable.

### 7. Validate each target independently

Compile and run native before enabling web. Compare images, clipping, blending,
text metrics, input transitions, camera calculations, render targets, and audio
against the frozen baseline. Then compile web and repeat the checks in a real
WebGPU browser. A native pass does not establish browser asset, lifecycle, input,
audio, accessibility, or GPU behavior.

## Mechanical source changes and examples

The matrix is authoritative for migration classification. These snippets show
the most common transitions; they do not widen the supported surface.

### Imports and build command — mechanical edit

```odin
// Before.
import rl "vendor:raylib"

// After.
import rl "ingot:gfx"
```

```sh
# Before.
odin build src

# After.
odin build src -collection:ingot=libs/ingot
```

### Native loop to shared native/web loop — mechanical edit

```odin
// Before: native blocking loop.
for !rl.WindowShouldClose() {
	frame()
}

// After: blocks natively and registers the callback on web.
rl.run(frame)
```

Keep callback state in global, static, heap, or otherwise application-owned
storage. Do not capture pointers to `main` locals for the web callback.

### Texture lifetime — unchanged call shape

```odin
image := rl.LoadImage("assets/player.png")
texture := rl.LoadTextureFromImage(image)
rl.UnloadImage(image)

// DrawTexture or DrawTexturePro during a frame.

rl.UnloadTexture(texture)
```

On web, `assets/player.png` must be hosted at the URL resolved by the page. Check
that the image and texture handles are valid before drawing.

### Render textures — unchanged call shape, behavior review

```odin
target := rl.LoadRenderTexture(640, 360)

rl.BeginTextureMode(target)
rl.ClearBackground(rl.BLANK)
rl.DrawCircle(320, 180, 48, rl.WHITE)
rl.EndTextureMode()

rl.DrawTexturePro(
	target.texture,
	{0, 0, 640, -360},
	{0, 0, 640, 360},
	{0, 0},
	0,
	rl.WHITE,
)

rl.UnloadRenderTexture(target)
```

The negative source height is the established fixture convention when presenting
a render texture. Validate orientation instead of applying it blindly to every
asset path.

### 2D cameras — unchanged call shape

```odin
camera := rl.Camera2D {
	offset   = {f32(rl.GetScreenWidth()) / 2, f32(rl.GetScreenHeight()) / 2},
	target   = player_position,
	rotation = 0,
	zoom     = 2,
}

rl.BeginMode2D(camera)
// World-space draws: these pan, zoom, and rotate with the camera.
rl.DrawRectangleRec(ground, rl.DARKGREEN)
rl.DrawTextureV(player_texture, player_position, rl.WHITE)
rl.EndMode2D()

// Screen-space draws: outside the mode, so the HUD stays put.
rl.DrawText("score", 12, 12, 20, rl.WHITE)
```

`zoom` must be non-zero for the camera to be invertible. `GetScreenToWorld2D`
returns the camera target rather than raylib's infinities when it is not, so
picking code cannot propagate NaNs into layout.

Cameras do not nest, matching raylib. A camera composes on top of any active
`rlgl` matrix-stack offset and restores it on `EndMode2D`.

### Custom shaders — redesign

```odin
// Before: raylib accepts GLSL source selected for its OpenGL backend.
shader := rl.LoadShaderFromMemory(glsl_vertex, glsl_fragment)

// After: pass a WGSL module following Ingot's binding contract.
shader := rl.LoadShaderFromMemory(nil, wgsl_module)
```

The WGSL module must expose `vs_main` and `fs_main`. Projection is group 0,
primary texture and sampler are group 1, reflected custom uniforms are group 2,
and up to four extra sampled textures plus their sampler are group 3. Port and
review uniform layout; this is not syntax translation alone.

### Audio — unchanged basic calls, behavior review

```odin
rl.InitAudioDevice()
sound := rl.LoadSound("assets/confirm.ogg")

if rl.IsSoundReady(sound) {
	rl.PlaySound(sound)
}

rl.UnloadSound(sound)
rl.CloseAudioDevice()
```

Native file loading is synchronous. Browser file loading fetches and decodes the
hosted URL asynchronously, and playback may remain unavailable until a user
gesture unlocks WebAudio. `LoadSoundFromWave` is the synchronous cross-target
path used by [Breakout](../examples/breakout/main.odin).

### Web-safe persistent state — mechanical edit

```odin
App_State :: struct {
	texture: rl.Texture2D,
	ready:   bool,
}

app: App_State

main :: proc() {
	rl.InitWindow(800, 450, "shared app")
	app.texture = load_texture()
	app.ready = app.texture.id != 0
	rl.run(frame)
}

frame :: proc() {
	rl.BeginDrawing()
	rl.ClearBackground(rl.BLACK)
	if app.ready {
		rl.DrawTexture(app.texture, 24, 24, rl.WHITE)
	}
	rl.EndDrawing()
}
```

Native cleanup can run after `rl.run` returns. Browser teardown is host-managed;
do not unload callback resources immediately after `rl.run`, because it returns
as soon as the callback is installed.

## Features requiring redesign

Use `RenderTexture2D` rather than assembling compatibility framebuffers. Port
GLSL and OpenGL state to WGSL and explicit WebGPU state. Port depth-sensitive
meshes, models, animation, and instancing to Ingot's explicit GPU 3D API or an
application-owned renderer. Replace touch, gesture, broad image processing,
screenshot, and advanced audio calls with application code or another package;
[Compatibility](compatibility.md#not-implemented-and-not-planned) lists what
Ingot will not implement and why.

Do not rely on these compatibility behaviors as rendered implementations:

- `UpdateMusicStream` has no effect because each backend owns refill behavior.
  This is the only graphics or audio procedure Ingot ships that accepts a call
  and does nothing; see
  [what compiles is what works](compatibility.md#what-compiles-is-what-works).
- Compatibility meshes can be projected 2D approximations rather than geometry.
- Low-level `rlgl` is not a general immediate-mode OpenGL layer.

The no-op procedures previously listed here — `SetMouseOffset`, `SetDepthMask`,
`rlgl.EnableDepthMask`/`DisableDepthMask`, and the `rlgl` framebuffer
enable/attach/complete calls — have been removed. A dependency on any of them is
now a compile error at the call site rather than a silent absence of output.

## Native versus web lifecycle

`rl.run(frame)` uses one source-level call but two host lifecycles. Native blocks
until the window closes. Web stores `frame`, returns to JavaScript, and lets
`requestAnimationFrame` invoke it. Persistent state must therefore outlive
`main`, and browser teardown must be coordinated through the managed web session.

Browser paths are URLs, file-backed audio is asynchronous, clipboard and input
are subject to browser policy, page presentation owns the icon, and audio may
need a gesture. Native and web builds must be validated independently.

## Validation checklist

Framework changes affecting the compatibility surface must pass:

```sh
bash scripts/test.sh
bash scripts/check.sh
bash scripts/check-web.sh
```

The strict native gate builds `examples/raylib_migration_fixture`; the web gate
compiles the same fixture for `js_wasm32`. These are compile and deterministic
test gates. They do not replace a windowed render comparison or real browser and
GPU validation.

Before accepting an application migration, verify:

- The application compiles from a clean checkout with pinned Odin and Ingot
  revisions and the explicit `ingot` collection registration.
- Every raylib and `rlgl` dependency is classified, and no unsupported call is
  hidden behind a compatibility wrapper.
- No visual result depends on `SetMouseOffset`, compatibility framebuffer
  attachment, compatibility depth-mask state, or an unported low-level draw.
- Native screenshots match the baseline for shapes, clipping, text, textures,
  render-target orientation, shaders, blending, and depth-sensitive content.
- Logical and render dimensions, pointer coordinates, resize behavior, and
  HiDPI output are correct on representative displays.
- Keyboard transitions, text entry, IME, mouse, clipboard, gamepad connection,
  buttons, and axes work on representative native hardware.
- Sounds and music load, become ready, play, stop, loop, and unload; browser
  audio is tested before and after the required user gesture.
- Web assets resolve from their deployed URLs, persistent frame state survives
  after `main`, and managed-session teardown releases the application once.
- Native rendering runs on each supported backend being claimed: Metal on
  macOS, D3D12 on Windows, and Vulkan on Linux.
- A real WebGPU browser validates rendering and lifecycle. Node and compile-only
  gates are not reported as browser, accessibility, or GPU evidence.

Record the exact revision and hardware evidence in
[Production readiness](production-readiness.md) when making a release claim.

## Known limitations and issue reports

The compatibility matrix describes the current known limitations. Re-check it at
every pinned-revision upgrade because Ingot does not yet publish semantic-versioned
releases. A newly compiling call is not evidence that its behavior matches
raylib, and an enum value does not establish backend support.

A compatibility report should include:

- The smallest source reproducer and its classification from this guide.
- Ingot Git revision and complete `odin version` output.
- Operating system, architecture, GPU, driver, and selected WebGPU backend.
- Browser and version for web failures, plus the served asset URL layout.
- Exact build or run command and whether all three project gates pass.
- Expected raylib behavior, observed Ingot behavior, and a screenshot or render
  capture when the problem is visual.
- Whether the migration fixture, Breakout, and render fixture reproduce the
  failure.

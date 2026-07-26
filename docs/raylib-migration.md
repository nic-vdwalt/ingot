# Migrating from raylib

## Supported migration profile

Ingot provides targeted source compatibility for common 2D Odin applications,
not a complete implementation of raylib, raymath, raylib 3D, shaders, or `rlgl`.
The best candidates use the window and frame lifecycle, 2D shapes, textures,
render textures, custom fonts, keyboard/mouse input, and basic audio or gamepad
input. Applications built around models, animation, GLSL, raw OpenGL state, or
low-level `rlgl` rendering require a manual WebGPU port.

Compatibility covers the documented PascalCase procedures and public layouts in
`ingot:gfx` at a pinned Ingot revision. Internal registries, private procedures,
and undocumented bridge behavior are not stable APIs. A successful compile
proves source compatibility only; it does not prove visual, timing, input,
audio, browser, or GPU-backend equivalence.

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
| Window lifecycle and configuration | **Import-only** core; **behavior change** for platform flags | `SetConfigFlags`, `InitWindow`, `WindowShouldClose`, dimensions, timing, and `CloseWindow` use the default compatibility context. HiDPI, transparency, custom chrome, and platform flags require native validation. A browser owns its canvas and page lifecycle. | [`gfx/context.odin`](../gfx/context.odin), [platform limits](compatibility.md#graphics-and-window-limitations) |
| Frame loop | **Mechanical edit** for native/web shared source | `BeginDrawing`, `ClearBackground`, and `EndDrawing` retain their shape. Prefer `rl.run(frame)` for shared source: it blocks natively and registers a browser animation callback on web. State reached by `frame` must outlive `main` on web. | [`gfx/context.odin`](../gfx/context.odin), [`gfx/loop_web.odin`](../gfx/loop_web.odin), [`gfx/platform_native.odin`](../gfx/platform_native.odin) |
| 2D shapes and scissor | **Import-only** | The documented rectangle, line, triangle, circle, ring, and scissor calls feed Ingot's WebGPU batch renderer. Compare antialiasing, edge coverage, and blending visually. | [`gfx/shapes.odin`](../gfx/shapes.odin), [`examples/render_fixture`](../examples/render_fixture/main.odin) |
| Colors and basic math types | **Import-only** core; **unsupported** as full raymath | `Color`, `Vector2`, `Vector3`, `Vector4`, `Rectangle`, camera types, and common matrix helpers are available. This does not provide the complete raymath package. | [`gfx/types.odin`](../gfx/types.odin), [`gfx/camera.odin`](../gfx/camera.odin) |
| Images and textures | **Import-only** for documented loading/drawing; **behavior change** for formats and web assets | `Image`, `Texture2D`, file/memory image loading, texture creation, filtering, drawing, and unload calls cover the common path. The WebGPU registry owns GPU resources; format support is narrower than the enum list implies, and browser paths are hosted URLs rather than native filesystem assumptions. | [`gfx/types.odin`](../gfx/types.odin), [`gfx/texture.odin`](../gfx/texture.odin) |
| Render textures | **Import-only** core; **behavior change** for orientation and depth | `LoadRenderTexture`, `BeginTextureMode`, `EndTextureMode`, and unload are real WebGPU render targets. Validate source-rectangle Y orientation. Compatibility render targets do not imply arbitrary framebuffer attachment parity. | [`gfx/render_target.odin`](../gfx/render_target.odin), [render-target contract](rendering.md#render-targets) |
| Text and fonts | **Mechanical edit** when code inspects layouts; **behavior change** for fallback text | Custom font loading, `DrawTextEx`, `MeasureTextEx`, and unload are supported. `Font` exposes only the fields Ingot consumers use, not raylib's complete public layout. The default `DrawText` path is currently a fallback stub, so production text should load and use a custom font. | [`gfx/types.odin`](../gfx/types.odin), [`gfx/text.odin`](../gfx/text.odin) |
| Keyboard, mouse, clipboard, and cursor | **Import-only** core; **behavior change** for platform seams | Documented key/button transitions, character queues, mouse position/delta/wheel, clipboard, and cursor calls are present. `SetMouseOffset` is a compatibility no-op. IME behavior is platform-specific and incomplete on some native platforms. | [`gfx/input.odin`](../gfx/input.odin), [`gfx/ime_other.odin`](../gfx/ime_other.odin) |
| Cameras | **Mechanical edit** for `Camera2D`; **behavior change** for compatibility 3D | Camera types and common projection helpers are available, but Ingot does not currently expose raylib's `BeginMode2D`/`EndMode2D` pair. Apply 2D camera transforms in application code or the UI/layout layer. Compatibility `BeginMode3D` projects on the CPU into the 2D batch and is not a depth-capable raylib 3D renderer. | [`gfx/types.odin`](../gfx/types.odin), [`gfx/camera.odin`](../gfx/camera.odin) |
| Audio and music | **Import-only** basic calls; **behavior change** on web and for streaming | Device, sound, wave, playback, volume, pitch, and music calls cover the basic API. Browser file loads are asynchronous hosted-URL fetches and may require a user gesture. Poll `IsSoundReady` or `IsMusicReady`. `UpdateMusicStream` intentionally has no effect; native music streams on the device thread while web music is fully decoded. `Sound` and `Music` layouts are not full raylib layouts. | [`gfx/audio.odin`](../gfx/audio.odin), [`gfx/audio_web.odin`](../gfx/audio_web.odin) |
| Gamepads | **Import-only** queries; **behavior change** by host | Availability, names, buttons, transitions, and six standard axes are mapped to raylib-shaped enums. Browser and native controller mappings, connection policy, and device support still require representative hardware tests. | [`gfx/types.odin`](../gfx/types.odin), [`gfx/input.odin`](../gfx/input.odin) |
| Shaders | **Manual port** | Procedure names resemble raylib, but shader source must be WGSL, not GLSL. Ingot expects fixed bind groups, `vs_main`/`fs_main` entry points, a reflected `struct U`, and at most four extra sampled textures. Port shader code and resource bindings explicitly. | [`gfx/shader.odin`](../gfx/shader.odin), [rendering](rendering.md) |
| Blend modes | **Behavior change** | Standard batch modes select WebGPU pipelines with premultiplied inputs. Custom factors are translated from a limited set of GL-style constants. Validate equations and alpha output rather than assuming OpenGL blending equivalence. | [`gfx/gpu3d.odin`](../gfx/gpu3d.odin), [`gfx/rlgl/rlgl.odin`](../gfx/rlgl/rlgl.odin) |
| 3D, models, meshes, and materials | **Manual port**; **unsupported** for general raylib model/animation APIs | Compatibility lines, billboards, spheres, and meshes are CPU-projected 2D approximations without compatibility-path depth behavior. `DrawMesh` renders a shaded disc and `UnloadMesh` has no work. Use Ingot's explicit depth-capable GPU 3D API for supported mesh work; general model loading, skeletal animation, and raylib material parity are not production features. | [`gfx/camera.odin`](../gfx/camera.odin), [`gfx/render3d.odin`](../gfx/render3d.odin), [`gfx/gpu3d.odin`](../gfx/gpu3d.odin) |
| `rlgl` batch and 2D matrix calls | **Behavior change** | `DrawRenderBatchActive` performs a real batch flush. The matrix shim supports the limited 2D translation used by existing consumers. It is not an immediate-mode OpenGL layer. | [`gfx/rlgl/rlgl.odin`](../gfx/rlgl/rlgl.odin) |
| `rlgl` vertex arrays and buffers | **Manual port** | Calls retain selected signatures for source compatibility, but the compatibility implementation is limited to an internal instancing path and is not a general immediate-mode renderer. Port low-level drawing to explicit WebGPU or Ingot GPU 3D. | [`gfx/rlgl/rlgl.odin`](../gfx/rlgl/rlgl.odin), [`gfx/rlgl_vao.odin`](../gfx/rlgl_vao.odin) |
| `rlgl` framebuffers and depth state | **Manual port** | Framebuffer enable/attach calls are bookkeeping no-ops and completion only checks for a non-zero ID. Compatibility `SetDepthMask` records state without changing the CPU-projected 2D approximation. Use `RenderTexture2D` or explicit GPU targets instead. | [`gfx/rlgl/rlgl.odin`](../gfx/rlgl/rlgl.odin), [`gfx/camera.odin`](../gfx/camera.odin) |
| Window icons | **Behavior change** | Native hosts may apply icon operations, but the browser owns page icons and window presentation. Treat icon setup as platform packaging, not cross-target rendering state. | [`gfx/platform_native.odin`](../gfx/platform_native.odin), [`gfx/platform_web.odin`](../gfx/platform_web.odin) |
| Touch, gestures, image processing, advanced audio, and broad raylib utilities | **Unsupported** unless a specific Ingot procedure is documented | Do not infer support from a related type or enum. Replace these features with application code, another package, or an approved Ingot addition. | [`gfx/api.odin`](../gfx/api.odin), [compatibility policy](compatibility.md#versioning-policy) |

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
application-owned renderer. Replace unsupported touch, gesture, broad image
processing, and advanced audio calls with application code or another package.

Do not rely on these compatibility behaviors as rendered implementations:

- `SetMouseOffset` has no effect.
- `UpdateMusicStream` has no effect because each backend owns refill behavior.
- `rlgl` framebuffer enable/attach calls are bookkeeping only.
- Compatibility depth-mask state has no visual effect on CPU-projected 3D.
- Compatibility meshes can be projected 2D approximations rather than geometry.
- Low-level `rlgl` is not a general immediate-mode OpenGL layer.

## Native versus web lifecycle

`rl.run(frame)` uses one source-level call but two host lifecycles. Native blocks
until the window closes. Web stores `frame`, returns to JavaScript, and lets
`requestAnimationFrame` invoke it. Persistent state must therefore outlive
`main`, and browser teardown must be coordinated through the managed web session.

Browser paths are URLs, file-backed audio is asynchronous, clipboard and input
are subject to browser policy, page presentation owns the icon, and audio may
need a gesture. Native and web builds must be validated independently.

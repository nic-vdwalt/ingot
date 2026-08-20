# Compatibility and platforms

Ingot targets macOS/Metal, Windows/D3D12, Linux/Vulkan, and browser WASM/WebGPU
from one application source. Shared API shape does not imply identical host
capabilities; applications must handle unavailable platform services.

## Versioning policy

Ingot publishes pre-`1.0` source tags. Any `0.x` tag may change documented
public APIs, including through breaking changes; every such change is recorded
in the [changelog](../CHANGELOG.md). Pin exact tags and upgrade deliberately.

A planned removal receives a changelog migration entry. Where the old surface
can remain safely and without preserving a flawed boundary, it remains as a
compatibility facade for one minor release. Immediate removal is reserved for
security, correctness, or toolchain changes that cannot support such a window,
and the changelog records the reason.

Every tag is a **source** tag. Ingot distributes no binaries, installers, or web
bundles, and a tag does not authorize redistributing them; the
[binary and web release checklist](oss-release-checklist.md) governs that
separately. A tag also asserts nothing about platform validation. Consult the
revision-pinned evidence in [production readiness](production-readiness.md);
`Not recorded` rows remain unsupported claims for every release.

Pin a tag or an exact Git revision in application source control and CI. A tag is
the readable choice; an exact revision remains the strictest and is still
recommended for CI. Upgrade deliberately by reading the changelog, documentation,
and source changes, then run native, web, and application-specific validation
before updating the pin.

The tested compiler revision is recorded in `ODIN_VERSION`. Use that compiler,
its bundled `odinfmt`, and the repository `.odinfmt.json`. Compiler development
revisions can change language, ABI, vendor packages, and WebGPU runtime behavior;
a newer revision is not assumed compatible until the full gates pass. This
compiler and vendor ABI constraint is separate from Ingot's public source API
policy: matching application source may still require the toolchain pinned by
the selected Ingot revision.

The compatibility classes are:

- Documented application APIs in `ingot:gfx`, `ingot:ui`, `ingot:ui_gfx`,
  `ingot:net`, `ingot:prefs`, `ingot:sys`, and `ingot:term` receive the patch
  compatibility and migration policy above.
- Documented PascalCase graphics procedures and public type layouts are a
  targeted migration facade for common raylib-style 2D applications. This is
  not complete raylib, raymath, 3D, shader, or `rlgl` parity.
- `ingot:gfx/rlgl`, legacy networking entry points, direct `ui_gfx.Adapter`
  lifecycle procedures, and low-level binding packages are compatibility or
  implementation layers. They change only with an explicit changelog entry but
  are not recommended application defaults.
- Internal structures, private procedures, undocumented bridge details, and
  generated or staged web runtime files are not public APIs and carry no source
  compatibility guarantee.

Pin an Ingot tag or revision and review the graphics limitations below before
replacing imports.

## What compiles is what works

Ingot does not ship a graphics procedure that accepts a call and then renders
nothing. A feature this renderer cannot honour is absent, so depending on it is
a compile error at the call site rather than a blank region discovered later.
A successful `odin build` is therefore evidence that the calls your application
makes are implemented. It remains no evidence that their output matches raylib
pixel for pixel, which is what [Migrating from raylib](raylib-migration.md)
asks you to validate.

There is one documented exception. `UpdateMusicStream` does nothing because
both backends refill internally: native music streams on the miniaudio device
thread and browser music is fully decoded. Calling it is harmless, and omitting
it changes nothing.

`gfx.capabilities()` reports runtime-independent support boundaries for default
text, path texture loading, IME positioning, window controls, render targets,
the explicit GPU 3D API, raylib mesh compatibility, and general `rlgl`. Check it
before selecting platform-limited paths. The explicit GPU 3D API is supported;
legacy `GenMeshSphere`/`DrawMesh` remains an approximation and is reported
separately as unsupported raylib mesh compatibility.

`UpdateTexture` accepts RGBA8 data, matching the raylib facade. Code receiving
RGB, grayscale, or gray-alpha buffers uses `UpdateTextureChecked`, which requires
an explicit byte count and `PixelFormat` and rejects mismatched sizes.

## Compatibility and binding layers

The following surfaces exist for source migration, FFI, or framework
implementation. They are not normal application defaults:

- `ingot:gfx/rlgl` is a bounded raylib migration shim, not an OpenGL API.
- Host/port HTTP procedures and `ws_start_connect` are legacy plaintext paths;
  new code uses URL-based HTTP and `ws_start_connect_url`.
- `ingot:libvterm`, `ingot:pty`, and `ingot:accesskit` are bindings used by
  `term` and `ui_gfx`; applications start with those higher-level packages.
- Direct `ui_gfx.Adapter` lifecycle calls implement a renderer bridge; custom
  application loops use `ui_gfx.Session`.

Pinning preserves access to these layers, but does not make them equally suitable
for new consumer code. See [Choosing an API layer](api-layers.md).

## Not implemented, and not planned

These raylib surfaces are out of scope for Ingot. They are listed so that scope
is a settled question rather than an open one, and so a migration can be
classified without waiting on a future release:

- CPU image processing: the roughly fifty `Image*` procedures. Decode with
  `LoadImageFromMemory`, then process pixels in application code or a library.
- Models, meshes, materials, and skeletal animation. Use Ingot's explicit GPU
  3D API for depth-capable mesh work.
- All `DrawSpline*` procedures.
- Gestures and touch input.
- VR and stereo rendering.
- Complete raymath. Ingot exposes only the few helpers its own consumers use.
  `core:math/linalg` is Odin's general-purpose vector and matrix package and
  does not need a raylib-shaped wrapper.
- General immediate-mode `rlgl`. The shim covers the matrix stack, blend state,
  batch flush, and an internal instancing path. It is not an OpenGL layer.
- `TakeScreenshot`. Capturing the swapchain needs `CopySrc` usage on the surface
  across all four backends, an asynchronous buffer readback, and an image
  encoder, and a browser has nowhere to write the file. Read back from a
  `RenderTexture2D` in application code instead.

Requesting one of these is a design discussion, not a bug report.

## Graphics ownership layers

`ingot:gfx` exposes three ownership surfaces. PascalCase procedures are the
source-migration facade and call explicit implementations with `default_context()`.
The `Frame` API records one owner and passes it to every drawing implementation.
Explicit `Context` procedures own window, input, resource, and host integration.

New Ingot-native code should use `Frame` and `Context`. PascalCase remains
supported for the documented raylib migration subset, but is not a second
context-capable API and is not extended merely to mirror each explicit
capability.

Native 3D picking follows the same rule: `screen_to_world_ray`,
`intersect_plane`, `intersect_sphere`, and `intersect_bounds` are snake_case
Ingot APIs in the ROS world basis. They do not add PascalCase raylib collision
aliases or broaden the compatibility facade into complete raymath support.

Mixing is supported only for the default owner. Framework internals and
multi-context applications must use owned `Frame` or `Context` procedures.
There is no mutable active context and no scope that can reroute PascalCase calls
to another live context.

## Build dependencies

All targets require the pinned Odin toolchain and Bash for repository scripts.
`scripts/test.sh` requires Python 3. `scripts/check-web.sh` requires Node with the
built-in test runner. Native rendering requires the target wgpu-native library
expected by Odin's `vendor:wgpu`. Native HTTPS and WSS use libcurl. Ingot always
enables peer and hostname verification; deployments must provide libcurl's CA
trust source.

Linux additionally requires a C toolchain, `pkg-config`, libcurl and Vulkan
development files, plus the X11 libraries used by Odin's GLFW package. Run
`bash scripts/check-linux-dependencies.sh` before compiling; it validates these
inputs and builds the architecture-matched libvterm archive from pinned vendored
source. `xdg-open`, `zenity`, and `kdialog` are optional runtime helpers. Linux
AccessKit is enabled on amd64 only; arm64 compiles without native accessibility
until a verified archive exists. macOS-to-Linux cross-compilation is not
supported by the repository scripts.

The core framework API is written in Odin, but native integration is not
literally dependency-free or pure Odin. Applications that omit terminal or
accessibility features need not initialize those services.

### macOS binary size

A macOS build carries its zero-initialised globals verbatim, so `ingot`'s fixed
capacity pools - `gfx.Context` is around 11 MB, mostly the batch arrays - are
present in full. A gallery build is about 28 MB, over half of it zeros.

This is a consequence of Odin's default parallel build, not a defect. Separate
modules compile each package independently, so a global may be emitted more
than once and must carry `weak` linkage for the linker to select a definition.
Mach-O cannot place a weak symbol in a zerofill section, because a weak
definition has to be materialised to be chosen. ELF has no such restriction, so
the same source targeting Linux does use `.bss`.

`-use-single-module` switches the global to `internal` linkage and restores
zerofill placement, roughly halving the binary (28.4 MB to 14.5 MB for the
gallery) at the cost of non-parallel compilation. Consider it for release
builds where distribution size matters; measure the build-time cost first.

Nothing about this affects the WASM target, which is always single-module.

## Browser hosting

`bash build_web.sh` writes `web/ingot_web.wasm`. Serve the `web/` directory over
HTTP; loading from `file://` is unsupported. Use a WebGPU-capable secure context.
The current baseline is Chrome/Edge 113+ or Safari 18+, subject to operating-
system GPU support and browser policy.

Consumer builds should call `scripts/stage-web-runtime.sh DEST`. The script
copies the pinned Odin runtime, WebGPU runtime, and Ingot host glue and applies
the required compatibility transform. It does not copy application WASM or an
HTML entry point. Keep staged runtime files and the compiled WASM from the same
Ingot/Odin revision.

`ingotWeb.run()` returns a managed session. Retain it and call
`session.destroy()` before replacement, or call `ingotWeb.stop()` for global
teardown. Only one managed active application session is supported per host
page. Strict CSP packaging and content-hashed assets remain application/release
work.

Browser limitations include:

- No filesystem paths from open/save dialogs. Use drag-and-drop, file inputs,
  or host-provided download links.
- Preferences use `localStorage` keys of the form `app/file`; quota, private
  browsing, storage policy, and user clearing can make persistence unavailable.
- `sys.cache_dir` is unavailable because there is no native cache path.
- HTTP is governed by CORS, mixed-content, credential, redirect, and forbidden-
  header rules. WebSocket TLS and certificates are browser managed.
- Audio may require a user gesture before playback.
- Accessibility uses a semantic DOM overlay and requires real browser/screen-
  reader validation.
- PTY and native terminal process spawning are unavailable.

### Module size and serving

A demo module is roughly 1.2 MB, of which the data section is a few hundred
kilobytes. Two properties of the toolchain make that number easy to lose by
accident, and both have bitten this repository:

**Serve WASM compressed.** The module is highly compressible - the demos reach
roughly 24x - and browsers request `Content-Encoding: gzip` for it like any
other asset. Some servers omit `application/wasm` from their compressible MIME
list and cannot be overridden per-directory (LiteSpeed is one), in which case
pre-compress at deploy time and negotiate with a rewrite. An uncompressed
multi-megabyte module is not only slow: a transfer cut short on a mobile
connection surfaces only as `unexpected end of data` from the WASM parser, with
nothing pointing at the download.

**Do not statically initialise a large global.** WebAssembly memory is
zero-initialised by specification, so an all-zero global costs nothing in the
module. Give it any non-zero initialiser and LLVM must move the *entire* object
from `.bss` into `.data`, where every byte is emitted verbatim:

```odin
// 11 MB of zeros in every module, from four bytes of initialiser.
default_context_storage: Context = {id = 1}

// Nothing in the module; the id is assigned before main.
default_context_storage: Context

@(init, private)
_default_context_init :: proc "contextless" () {
	default_context_storage.id = DEFAULT_CONTEXT_ID
}
```

`gfx.Context` is around 11 MB, mostly the batch vertex and index arrays, so
that single field cost 11.1 MB - the demo modules were 12.3 MB rather than
1.2 MB. This is ordinary LLVM behaviour, not an Odin defect; C reproduces it
exactly. `scripts/check_wasm_bloat.py` runs in `scripts/check-web.sh` and fails
any data segment over 64 KB that is more than half zeros, so a future
initialiser cannot quietly reintroduce it.

## Native system integration

### Preferences and cache paths

`prefs.data_dir` resolves `%APPDATA%/<app>` on Windows and
`~/.local/share/<app>` on macOS/Linux, with environment-based fallbacks.
`prefs.write` creates directories; `prefs.read` returns allocator-owned bytes to
the caller. App and file names remain application-controlled path components and
must not contain untrusted traversal.

`sys.cache_dir` resolves `%LOCALAPPDATA%`, `~/Library/Caches`, or
`$XDG_CACHE_HOME`/`~/.cache` according to platform. It validates a bounded app
identifier but does not validate data later read from the directory.

### Dialogs

Native open/save dialogs block until dismissed and return `ok = false` for
cancel or dispatch failure. Returned paths are allocator-owned and untrusted.
Validate permissions, symlinks, file type, and size before use.

macOS uses `osascript`; Linux tries host dialog helpers and therefore depends on
an available supported helper and graphical session; Windows uses the native
common-dialog API. Browser procedures report unavailable rather than exposing a
fake path.

### Opening URLs

`sys.open_url` allows only schemes explicitly enabled in `Open_URL_Options`,
rejects control characters and oversized values, and reports dispatch failure.
The defaults allow `http` and `https`; enable `mailto` only where intended.
Treat all externally supplied URLs as untrusted even after scheme validation.

### Terminal and PTY

Unix uses `forkpty`; Windows uses ConPTY. The terminal package binds libvterm and
owns bounded pump, resize, input translation, and clipboard-paste behavior.
Applications must close PTYs, reap child processes, destroy terminal state, and
perform real platform validation. The ordinary test suite uses a simulator and
does not spawn a shell.

## Graphics and window limitations

The compatibility graphics facade owns one default context so documented common
2D calls can retain their familiar shape after the package import changes.
Applications outside that surface require the edits described in
[Migrating from raylib](raylib-migration.md). Native applications may also create
explicit contexts and interleave independently live windows on one owner thread.
Parallel renderer threads and browser multi-canvas hosting are not production
guarantees. HiDPI, transparency, vibrancy/Mica, drag-and-drop, IME, gamepad,
audio, accessibility, and custom chrome have platform seams and require
validation on representative hardware.

WebGPU backend selection and optional features vary by operating system, GPU,
driver, and browser. A successful compile demonstrates source compatibility,
not runtime validation. Record backend and hardware details using the matrix in
[Production readiness](production-readiness.md).

## Support reporting

When reporting a compatibility issue, include:

- Ingot Git revision and `odin version` output.
- Operating system and architecture.
- GPU, driver, and selected WebGPU backend for graphics failures.
- Browser and version for web failures.
- Exact command and smallest reproducer.
- Whether package tests, strict checks, web checks, and the render fixture pass.

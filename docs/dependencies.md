# Dependencies and package composition

Ingot has no umbrella package. Applications import only the capabilities they
use, and package boundaries determine which optional native artifacts are
linked. These are compile-time compositions, not runtime profiles.

## Compositions

| Application | Imports | Additional boundary |
|---|---|---|
| Minimal GUI | `ingot:fit` | WebGPU/wgpu-native, GLFW by default or opt-in SDL3, stb, bundled font |
| Advanced GUI | `ingot:ui`, `ingot:ui_gfx`, `ingot:gfx` | Same graphics boundary; more lifecycle responsibility |
| Accessible GUI | GUI packages; `ui_gfx` owns the host bridge | Native AccessKit where available; semantic DOM in browser |
| Networked tool | GUI packages plus `ingot:net` | Native libcurl; browser Fetch/WebSocket APIs |
| Terminal tool | GUI packages plus `ingot:term` | `ingot:pty`, `ingot:libvterm`, platform PTY/ConPTY |
| Graphics application | `ingot:gfx` | WebGPU/wgpu-native and exactly one native host: GLFW or SDL3 |
| Engine application | Explicit `asset`, `ecs`, `mesh`, `noise`, `scene`, or `scene_gfx` imports | No GUI dependency is implied |

A minimal GUI must not import `net`, `term`, `pty`, `libvterm`, `accesskit`,
`ecs`, `mesh`, `noise`, `scene`, or `scene_gfx` directly. `ui_gfx` owns the optional
accessibility host integration; applications do not start with the binding
package.

## Toolchain

Use the exact Odin revision in [`ODIN_VERSION`](../ODIN_VERSION). Its bundled
`vendor:wgpu`, `vendor:glfw`, `vendor:sdl3`, `vendor:stb`, `vendor:miniaudio`,
`vendor:box3d`, `vendor:x11` (Linux drag-and-drop), and `vendor:curl` (the
Windows libcurl import library) packages are part of the tested build boundary.
A newer compiler or vendor archive is not assumed compatible.

The current compiler is built from upstream commit
`93f71c2751f0f8cb1d2a7a892ae4505f9af6d13d` (PR #7842), reporting
`dev-2026-10:93f71c2`. October's published compiler has a macOS Objective-C
regression (#7793); the pinned commit fixes it without a local source patch.
CI overlays this source on October's release assets and builds the compiler
with `build_odin.sh release` (macOS/Linux) or `build.bat release` (Windows).
Keep Git metadata at the exact commit so version output includes its revision
and commit month. On macOS, LLVM 20 is used; install the result at
`../tools/odin-93f71c2` or point `INGOT_ODIN_ROOT` to it.

GLFW is the default native host. `-define:INGOT_GFX_SDL3=true` selects SDL3
3.4.x at compile time while retaining `vendor:wgpu`; the unselected host is not
linked. Browser builds continue using DOM events and WebGPU directly.

On Windows, pass `-linker:msvc` (or `-linker:lld`) to every `odin build`,
`run`, or `test` that links `ingot:gfx`. Odin dev-2026-10 made radlink the
default Windows linker; radlink stops on the Rust runtime symbols
(`rust_eh_personality` and friends) that both `vendor:wgpu` and the committed
`accesskit.lib` define, and it ignores the `/FORCE:MULTIPLE` flag that
`accesskit.odin` passes for link.exe and lld-link. `scripts/test.ps1` and
`scripts/check.ps1` already do this; `odin check` does not link and must not
receive the flag.

## Platform prerequisites

| Target | Required | Optional application services |
|---|---|---|
| macOS | Pinned Odin and bundled wgpu-native/GLFW inputs; SDL3 3.4.x for SDL builds | AccessKit, libcurl, libvterm according to imported packages |
| Windows | Pinned Odin and bundled wgpu-native/GLFW inputs; SDL3 3.4.x for SDL builds; `link.exe` (Visual Studio Build Tools) for `-linker:msvc` | AccessKit, libcurl, ConPTY/libvterm according to imports |
| Linux | C toolchain, `pkg-config`, Vulkan and GLFW/X11 files; SDL3 3.4.x for SDL builds | libcurl for `net`; libvterm for `term`; desktop dialog helpers |
| Browser | Pinned Odin, Node for repository checks, a WebGPU-capable browser at runtime | Browser networking and semantic DOM according to application use |

Run `bash scripts/check-linux-dependencies.sh` on Linux. Windows and macOS CI
workflows document their pinned setup. Repository gates may build optional
subsystems even when a particular consumer does not import them; that verifies
the repository, not the consumer's link set.

## Assets and network independence

Normal application builds do not download fonts, Unicode data, JavaScript
runtime files, or native archives. The bundled JetBrains Mono source asset and
committed native binding artifacts have recorded provenance in
[`THIRD_PARTY_NOTICES.md`](../THIRD_PARTY_NOTICES.md). Web runtime staging uses
files from the pinned Odin installation.

## Distribution

Source tags do not authorize or certify binary redistribution. Before shipping
a binary, installer, or web bundle:

1. Complete [`oss-release-checklist.md`](oss-release-checklist.md).
2. Inventory the exact linked packages and system libraries.
3. Generate an SBOM for the produced artifact.
4. Include `LICENSE`, `NOTICE`, `THIRD_PARTY_NOTICES.md`, and applicable
   toolchain/runtime notices.
5. Record the source, toolchain, build command, artifact hash, and validation
   evidence.

Package composition reduces unused linkage; it does not waive third-party
license or platform validation obligations for code that is actually shipped.

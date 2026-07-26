# Compatibility and platforms

Ingot targets macOS/Metal, Windows/D3D12, Linux/Vulkan, and browser WASM/WebGPU
from one application source. Shared API shape does not imply identical host
capabilities; applications must handle unavailable platform services.

## Versioning policy

Ingot does not currently publish semantic-versioned releases. Pin an exact Git
revision in application source control and CI. Upgrade deliberately by reading
documentation and source changes, then run native, web, and application-specific
validation before updating the pin.

The tested compiler is Odin `dev-2026-06:285f6d87b`. Use the `odinfmt` bundled
with that toolchain and the repository `.odinfmt.json`. Compiler development
revisions can change language, ABI, vendor package, and WebGPU runtime behavior;
a newer revision is not assumed compatible until the full gates pass.

Public PascalCase graphics procedures and documented public type layouts form
the raylib-shaped compatibility surface. New Odin-style aliases are additive.
Internal structures, private procedures, generated web runtime files, and
undocumented bridge details are not stable APIs.

## Build dependencies

All targets require the pinned Odin toolchain and Bash for repository scripts.
`scripts/test.sh` requires Python 3. `scripts/check-web.sh` requires Node with the
built-in test runner. Native rendering requires the wgpu-native library expected
by Odin's `vendor:wgpu`; terminal and native accessibility features require the
committed libvterm and AccessKit libraries for the selected target. Native HTTPS
and WSS use libcurl. Ingot always enables peer and hostname verification; the
application deployment must provide libcurl's required CA trust source.

The core framework API is written in Odin, but native integration is not
literally dependency-free or pure Odin. Applications that omit terminal or
accessibility features need not initialize those services.

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

The compatibility graphics facade continues to own one default context, so
raylib-shaped applications require no source changes. Native applications may
also create explicit contexts and interleave independently live windows on one
owner thread. Parallel renderer threads and browser multi-canvas hosting are not
production guarantees. HiDPI, transparency, vibrancy/Mica, drag-and-drop, IME,
gamepad, audio, accessibility, and custom chrome have platform seams and require
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

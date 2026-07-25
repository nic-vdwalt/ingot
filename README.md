# ingot

**The app framework for Odin — ship a polished, fast, native + web desktop tool
without Electron.**

Ingot is a self-contained immediate-mode app framework with game-engine DNA,
built on Odin's bundled `vendor:wgpu`. One renderer targets macOS/Metal,
Windows/D3D12, Linux/Vulkan, and the browser through WASM + WebGPU. Two-dimensional
games are supported; polished desktop tools are the mission.

## Immediate mode is enough

Ingot's premise is that a retained widget tree is unnecessary. Anything a
retained GUI presents can be built by declaring the current interface from
explicit application state each frame. Persistence still exists, but it belongs
to the application or an explicit runtime service rather than a hidden tree or
label-hashed state store.

That distinction makes ownership visible and makes the machinery beneath the UI
straightforward to test. Input sequences can drive real widgets; assertions can
check bounded routing, focus, overlay, semantic, and resource-lifetime output;
and deterministic seeds can replay failures without reconstructing a private
object graph. This is a natural fit for Ingot's Tiger Style approach.

Read [Why immediate mode](docs/immediate-mode.md) for the argument and boundaries,
[Choosing Ingot](docs/comparison.md) for comparisons with other app and UI
stacks, [UI state and stable focus](docs/ui-state.md) for the ownership model,
and [Testing Ingot](docs/testing.md) for the deterministic and sanitizer-backed
harnesses.

## Highlights

- **Immediate mode all the way up.** Callers own persistent widget behavior;
  frames derive draw, interaction, overlay, focus, and accessibility output.
- **Pure Odin + WebGPU.** Built on Odin's bundled `vendor:wgpu`, `vendor:glfw`,
  and `vendor:stb`, with no external graphics stack to vendor.
- **Native and web from one source.** The same application compiles for desktop
  and WASM + WebGPU behind a small platform seam.
- **Raylib-shaped graphics API.** Familiar `Color`, `Vector2`, `Rectangle`,
  `Texture2D`, `Draw*`, and `IsKey*` names make migrations mechanical.
- **Native feel.** Platform-correct HiDPI, macOS vibrancy, Windows 11 Mica,
  custom window chrome, accessibility, and input behavior.
- **Energy-efficient.** Event-driven applications build no frame and submit no
  GPU work while idle; explicit redraw requests wake them when data changes.
- **Batteries included.** Windowing, batched 2D rendering, text, widgets, audio,
  gamepads, accessibility, settings, networking, and a terminal stack.

## Packages

| Package | Role |
|---|---|
| `ingot:gfx` | Windowing, WebGPU rendering, shapes, textures, text, input, audio, cameras, and a raylib/rlgl-shaped API |
| `ingot:ui` | Renderer-independent immediate-mode widgets, layout, paint output, input snapshots, accessibility semantics, and themes |
| `ingot:ui_gfx` | Adapter that captures `gfx` input, replays UI paint output, and applies platform output |
| `ingot:prefs` | Native settings files and web `localStorage` behind one API |
| `ingot:net` | Background HTTP and a reconnecting RFC 6455 WebSocket client |
| `ingot:sys` | URLs, native file dialogs, and platform integration |
| `ingot:term` | libvterm, PTY pumping, and key-to-terminal translation |
| `ingot:libvterm` | Odin bindings and committed native static libraries |
| `ingot:pty` | `forkpty` on Unix and ConPTY on Windows |

## Installation

Add Ingot as a submodule and register it as an Odin collection:

```sh
git submodule add <url> libs/ingot
odin build src -collection:ingot=libs/ingot
```

Pin the submodule revision in consumer CI. The tested Odin toolchain is
`dev-2026-06:285f6d87b`; use `odinfmt` built from the matching OLS revision and
place both executables on `PATH`. Native rendering also needs the wgpu-native
library expected by Odin's `vendor:wgpu` package. See
[Testing Ingot](docs/testing.md#toolchain) for verification commands.

```odin
import rl "ingot:gfx"
import ui "ingot:ui"
import "ingot:ui_gfx"
```

## Quick start

```odin
when ODIN_OS == .Darwin {
	rl.SetConfigFlags({.WINDOW_RESIZABLE, .VSYNC_HINT, .WINDOW_HIGHDPI})
} else {
	rl.SetConfigFlags({.WINDOW_RESIZABLE, .VSYNC_HINT})
}
rl.InitWindow(960, 640, "Ingot app")

runtime: ui.Ui_Runtime
frame: ui.Ui_Frame
input: ui.Ui_Input
output: ui.Ui_Output
adapter: ui_gfx.Adapter
ui.ui_runtime_init(&runtime)
ui_gfx.adapter_init(&adapter)
ui.ui_runtime_apply_platform_dpi(&runtime)

for !rl.WindowShouldClose() {
	ui_gfx.adapter_begin_frame(&adapter, &frame, &runtime, &input, &output)
	ui.ui_runtime_dpi_refresh(&runtime, dpi_scale = input.dpi_scale)
	rl.BeginDrawing()
	rl.ClearBackground(ui_gfx.color_to_gfx(ui.ui_frame_theme(&frame).bg_color))
	ui.draw_text_frame(&frame, "Hello from Ingot", 24, 24, 24, ui.ui_frame_theme(&frame).fg_primary)
	ui_gfx.adapter_end_frame(&adapter, &frame)
	rl.EndDrawing()
}

ui_gfx.adapter_destroy(&adapter)
ui.ui_runtime_destroy(&runtime)
rl.CloseWindow()
```

For an existing raylib application, replace `import rl "vendor:raylib"` with
`import rl "ingot:gfx"` and `vendor:raylib/rlgl` with `ingot:gfx/rlgl`. The API
shape keeps most `rl.*` call sites intact.

## See it running

`examples/gallery` is the living widget reference, including layout, text input,
overlays, charts, markdown, accessibility semantics, a 1,000-button stress view,
and an F12 metrics overlay.

```sh
odin run examples/gallery -collection:ingot=.
bash scripts/smoke-gallery.sh
```

Other focused examples:

- `examples/breakout` — audio, gamepad input, and web export from one source.
- `examples/idle_demo` — event-driven rendering at approximately zero idle CPU.
- `examples/chart_demo` — chart widgets and interaction.
- `examples/render_fixture` — renderer, resource-lifetime, and backend validation.

Build the browser demo with `bash build_web.sh`; validate web targets with
`bash scripts/check-web.sh`.

## Documentation

- [Why immediate mode](docs/immediate-mode.md) — the architecture's position,
  state boundary, retained-GUI capability mapping, and Tiger Style fit.
- [Choosing Ingot](docs/comparison.md) — comparisons with immediate, retained,
  web, native, raylib, and full game-engine alternatives.
- [UI state and stable focus](docs/ui-state.md) — runtime/frame/component
  ownership, teardown, focus identity, and accessibility identity.
- [Testing Ingot](docs/testing.md) — package tests, deterministic fuzzing,
  ASan/TSan, GPU validation, and reproducible seeds.
- [Rendering](docs/rendering.md) — renderer contracts, frame scheduling, backend
  validation, and render-target conventions.
- [Tiger Style](docs/TIGER_STYLE.md) — safety, performance, assertions, bounds,
  memory discipline, and contribution rules.

## Development

```sh
bash scripts/test.sh
bash scripts/check.sh
bash scripts/check-web.sh
```

The project prioritizes safety, then performance, then developer experience.
New and changed code follows bounded control flow, explicit ownership, strict
checking, and an average target of at least two assertions per procedure.

## Direction

The near-term priority is proof over feature count: validate every native WebGPU
backend, publish the live gallery, document a raylib migration, and report
concrete idle CPU, binary-size, and build-time measurements. Deeper app-engine
work includes docking, virtualized data views, accessibility validation, complex
text input, and Linux desktop-polish parity.

A 3D content pipeline, mobile targets, scripting layers, and editors remain out
of scope. Ingot's optional 3D path is a visualization escape hatch rather than a
scene-graph engine.

## License

See repository for license details.

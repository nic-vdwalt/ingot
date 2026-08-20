<p align="center">
  <img src="docs/media/ingot-logo.svg" width="720" alt="Ingot">
</p>

<p align="center">
  <strong>The Odin app framework for polished native and web desktop tools—without Electron.</strong>
</p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-Apache--2.0-blue.svg" alt="License: Apache-2.0"></a>
  <a href="CHANGELOG.md"><img src="https://img.shields.io/badge/targets-macOS%20%7C%20Linux%20%7C%20Windows%20%7C%20WASM%2FWebGPU-lightgrey.svg" alt="Targets: macOS, Linux, Windows, and WASM/WebGPU"></a>
</p>

<p align="center">
  <a href="https://openalloy.ai/ingot">Live demo and benchmarks</a>
</p>

Ingot is a self-contained immediate-mode framework built on Odin's bundled
`vendor:wgpu`. One renderer targets macOS/Metal, Windows/D3D12, Linux/Vulkan,
and browser WASM/WebGPU.

- Native and web builds from one source
- Immediate-mode UI for desktop tools
- Batched 2D graphics, input, audio, networking, accessibility, and terminals
- Event-driven rendering with near-zero idle work
- Deterministic, bounded test harnesses

> [!IMPORTANT]
> `0.1.7` is the latest source tag for a young `0.x` API. Pin an exact revision
> and validate every platform your application ships on.

## The experiment

Ingot explores whether deterministic simulation testing can shape an application
framework from the start. Explicit state, bounded work, and compile-gated seams
let seeded harnesses exercise production code without requiring a window, GPU,
network, shell, or assistive technology. This is an engineering experiment—not
a claim of correctness or production readiness. See [Testing](docs/testing.md).

## Quick start

```sh
git submodule add https://github.com/Nic-vdwalt/ingot.git libs/ingot
git -C libs/ingot checkout 0.1.7
odin build src -collection:ingot=libs/ingot
```

Use the Odin revision recorded in [`ODIN_VERSION`](ODIN_VERSION). For UI
applications, use the supported `ingot:fit` entry point:

```odin
package main

import "core:fmt"
import fit "ingot:fit"

App_State :: struct {
	button_clicks: u64,
}

app: fit.App
state: App_State

main :: proc() {
	_ = fit.Run(&app, {width = 960, height = 640, title = "Ingot app"}, Draw, &state)
}

Continue :: proc(user_data: rawptr) {
	assert(user_data != nil)
	state := cast(^App_State)user_data
	state.button_clicks += 1
}

Draw :: proc(builder: ^fit.Builder, user_data: rawptr) {
	assert(builder != nil && user_data != nil)
	state := cast(^App_State)user_data
	root := fit.Center(builder, {gap = .SM, padding = .LG})
	fit.Label(root, "Hello from Ingot")
	fit.Label(root, fmt.tprintf("Button clicks: %d", state.button_clicks))
	fit.Button(root, "continue", "Continue", fit.action(Continue, state))
}
```

Or use `ui_gfx` directly for immediate-mode UI:

```odin
package main

import "core:fmt"
import ui "ingot:ui"
import "ingot:ui_gfx"

App_State :: struct {
	button_clicks: u64,
}

app: ui_gfx.App
state: App_State

main :: proc() {
	_ = ui_gfx.app_run(
		&app,
		{
			width = 960,
			height = 640,
			title = "Ingot app",
			session = {semantics_enabled = true},
		},
		{ui = Draw},
		&state,
	)
}

Draw :: proc(app: ^ui_gfx.App, form: ^ui.Ui, user_data: rawptr) {
	assert(app != nil && form != nil && user_data != nil)
	state := cast(^App_State)user_data
	ui.padding(form, .LG)
	ui.label(form, "Hello from Ingot", ui.ui_frame_metrics(form.frame).FONT_SIZE_TITLE)
	ui.label(form, fmt.tprintf("Button clicks: %d", state.button_clicks))
	if ui.button(form, "continue", "Continue") {
		state.button_clicks += 1
	}
}
```

Run an example:

```sh
odin run examples/gallery -collection:ingot=.
```

## Explore

- [Widget gallery](examples/gallery/)
- [API map](https://openalloy.ai/demos/ingot-api-map/)
- [Why immediate mode](docs/immediate-mode.md)
- [Choosing Ingot](docs/comparison.md)
- [Examples](examples/)
- [Widget benchmarks](benchmarks/widgets/README.md)

## Documentation

- [API layers](docs/api-layers.md)
- [Testing](docs/testing.md)
- [Compatibility](docs/compatibility.md)
- [Rendering](docs/rendering.md)
- [Networking](docs/networking.md)
- [Migrating from raylib](docs/raylib-migration.md)
- [Production readiness](docs/production-readiness.md)

See [Contributing](CONTRIBUTING.md), [Security](SECURITY.md), and the
[Changelog](CHANGELOG.md). Licensed under [Apache 2.0](LICENSE); bundled works
are listed in [Third-party notices](THIRD_PARTY_NOTICES.md).

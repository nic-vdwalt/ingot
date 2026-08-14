# Supported API layers

Ingot has two supported consumer entry points.

## `ingot:gfx`

Use `ingot:gfx` as a raylib-compatible import. Keep the PascalCase window,
input, resource, drawing, camera, and audio calls used by the documented
compatibility subset. `ingot:gfx/rlgl` is available only where compatibility is
explicitly documented.

```odin
import rl "ingot:gfx"

main :: proc() {
	rl.InitWindow(800, 450, "App")
	defer rl.CloseWindow()
	for !rl.WindowShouldClose() {
		rl.BeginDrawing()
		rl.ClearBackground(rl.BLACK)
		rl.DrawText("Hello", 24, 24, 24, rl.RAYWHITE)
		rl.EndDrawing()
	}
}
```

The PascalCase API is the supported default-context migration vocabulary. The
narrow owner-bound `Frame` seam exists for framework bridges and documented
multi-context hosts; it is not a second general drawing vocabulary.

## `ingot:fit`

Use `ingot:fit` for UI applications. `fit.App` owns the graphics/UI lifecycle,
and the callback receives the only supported declaration object: `fit.Builder`.

```odin
import fit "ingot:fit"

app: fit.App
saved: bool

main :: proc() {
	_ = fit.Run(&app, {width = 720, height = 480, title = "App"}, Draw)
}

Draw :: proc(builder: ^fit.Builder, userdata: rawptr) {
	root_container: {
		fit.Column(builder, {gap = .SM, padding = .LG})
		defer fit.End(builder)
		fit.Label(builder, "Settings", {role = .Title})
		fit.Button(builder, "save", "Save", &saved)
	}
}
```

The builder is bounded and immediate. `Row`, `Column`, `Flow`, `Grid`, and
`Attachment` open containers; `End` closes one container. Static containers
should use a named lexical block with an immediate `defer fit.End(builder)`;
direct
closure remains available for dynamic construction. `Label`, `Button`,
`Checkbox`, `Radio`, `Slider`, and `Custom` emit leaves. The additive `*_With`
helpers auto-close callback-built containers; `Scope` provides explicit
component identity. `Render` consumes the declaration synchronously. `Measure`
plus `Render_At` supports caller-owned placement without introducing a retained
widget tree. A `Custom` render callback receives a borrowed `fit.Surface` for
same-frame interaction and explicit geometry; the Surface is valid only for that
callback and must not be retained.

For caller-owned scheduling, use the `fit.App` lifecycle explicitly:

```odin
main :: proc() {
	if !fit.Init(&app, {width = 720, height = 480, title = "App"}, {draw = Draw}) do return
	defer fit.Destroy(&app)
	if !fit.Start(&app) do return
	for fit.Get_State(&app) == .Running {
		if !fit.Tick(&app) do break
	}
	if fit.Get_State(&app) == .Running do _ = fit.Stop(&app)
}
```

`fit.Session` is reserved for bounded integration inside an externally owned
graphics loop. It still yields only `fit.Builder`; it does not expose runtime,
frame, adapter, paint, or platform internals.

## Internal packages

`ingot:ui` and `ingot:ui_gfx` retain the passive runtime, per-frame input and
paint state, prepared layout engine, explicit widget primitives, text backend,
platform output, accessibility bridge, and replay implementation. They remain
independently tested but are not supported application imports.

Likewise, `Prepared_Ui`, adapter lifecycle calls, raw `Ui`/`Ui_Frame` ownership,
and the removed `Fit_Node` tree are implementation details rather than parallel
consumer APIs.

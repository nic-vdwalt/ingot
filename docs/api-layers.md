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

The lower-case `Frame`/`Context` drawing vocabulary is implementation-only
while the bridge is migrated to direct context routing. New consumer code must
not adopt it.

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
	fit.Column(builder, {gap = .SM, padding = .LG})
	fit.Label(builder, "Settings", {role = .Title})
	fit.Button(builder, "save", "Save", &saved)
	fit.End(builder)
}
```

The builder is bounded and immediate. `Row`, `Column`, `Flow`, `Grid`, and
`Attachment` open containers; `End` closes one container. `Label`, `Button`,
`Checkbox`, `Radio`, `Slider`, and `Custom` emit leaves. The additive `*_With`
helpers invoke one child procedure immediately and auto-close their own
container; `Scope` provides explicit component identity. `Render` consumes the
declaration synchronously. `Measure` plus `Render_At` supports caller-owned
placement without introducing a retained widget tree.

For an existing raylib loop, use `fit.Session`:

```odin
session: fit.Session

main :: proc() {
	rl.InitWindow(720, 480, "App")
	fit.Session_Init(&session)
	defer fit.Session_Destroy(&session)
	defer rl.CloseWindow()
	rl.run(Frame)
}

Frame :: proc() {
	builder, acquired := fit.Session_Begin(&session)
	if !acquired do return
	fit.Column(builder)
	fit.Label(builder, "UI inside a raylib loop")
	fit.End(builder)
	fit.Session_End(&session)
}
```

## Internal packages

`ingot:ui` and `ingot:ui_gfx` retain the passive runtime, per-frame input and
paint state, prepared layout engine, explicit widget primitives, text backend,
platform output, accessibility bridge, and replay implementation. They remain
independently tested but are not supported application imports.

Likewise, `Prepared_Ui`, adapter lifecycle calls, raw `Ui`/`Ui_Frame` ownership,
and the removed `Fit_Node` tree are implementation details rather than parallel
consumer APIs.

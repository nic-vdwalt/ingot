# Application shell

`ui_gfx.App` is the common path for a one-window application. The caller owns the `App`, application state, and every persistent widget component. The shell owns only the default graphics context, `App_Session`, and frame ordering.

```odin
app: ui_gfx.App
state: State

main :: proc() {
	_ = ui_gfx.app_run(
		&app,
		{width = 960, height = 640, title = "App", session = {semantics_enabled = true}},
		{frame = draw, shutdown = shutdown},
		&state,
	)
}
```

The frame callback receives the explicit app and UI frame. Use `app_ui_begin` to open a caller-owned `Ui` across the client area, or `app_screen_rect` when the application owns explicit geometry. The shutdown callback runs while the graphics context is valid, so it must destroy caller-owned textures, input boxes, builders, and components there.

On native targets `app_run` blocks and performs shutdown after the window closes. On web it installs the browser callback and returns; therefore `App` and userdata must have static or otherwise retained lifetime. A managed web host remains responsible for stopping the module before replacement.

## Choosing the integration level

| Need | API |
|---|---|
| Typical one-window app | `ui_gfx.App` |
| Custom pacing or embedding | `ui_gfx.App_Session` |
| Renderer/platform integration | `ui_gfx.Adapter` |
| Forms and panels | `ui.Ui` layout |
| Canvas, scrolling, overlays | `*_at` and explicit geometry |
| Every interactive facade widget | Scoped `Widget_Id` |

`App_Session` remains the correct choice when an application needs a custom frame loop, explicit minimized-window handling, multiple graphics contexts, custom instrumentation, or unusual submission ordering.

## Ownership and teardown

The shell enforces this order:

1. Acquire the graphics frame.
2. Open the UI session frame.
3. Invoke application drawing.
4. Finalize semantics and replay UI output.
5. Submit the graphics frame.
6. Reset temporary frame allocations.
7. On shutdown, invoke caller cleanup.
8. Destroy UI frame, adapter, and runtime.
9. Close the graphics context.

No active application or frame is exposed through `ui`; callbacks always receive their owners explicitly.

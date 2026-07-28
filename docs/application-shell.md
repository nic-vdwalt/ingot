# Application shell

`ui_gfx.App` is the common path for a one-window application. The caller owns the
`App`, application state, and every persistent widget component. The shell owns
the default graphics context, `Session`, and frame ordering.

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

The frame callback receives the explicit app and UI frame. Use `app_ui_begin` to
open a caller-owned `Ui` across the client area, or `app_screen_rect` when the
application owns explicit geometry. The shutdown callback runs while the
graphics context is valid, so it must destroy caller-owned textures, input
boxes, builders, and components there.

On native targets `app_run` blocks and performs shutdown after the window closes.
On web it installs the browser callback and returns; therefore `App` and userdata
must have static or otherwise retained lifetime. A managed web host remains
responsible for stopping the module before replacement.

## Choosing the integration level

| Need | API |
|---|---|
| Typical one-window app | `ui_gfx.App` |
| Custom pacing, embedding, or multiple contexts | `ui_gfx.Session` |
| Renderer/platform bridge implementation | backend `ui_gfx.Adapter` procedures |
| Forms and panels | Flow UI through `ui.Ui` |
| Canvas, scrolling, and overlays | `canvas_*`, `*_at`, and explicit geometry |
| Every interactive facade widget | scoped `Widget_Id` |

`Session` is the supported custom-loop owner. It contains `Ui_Runtime`, the
reusable `Ui_Frame`, the captured `Ui_Input`, `Ui_Output`, and the backend
adapter. Applications should not declare those values separately.

```odin
session: ui_gfx.Session
ui_gfx.session_init(&session, {semantics_enabled = true})
defer ui_gfx.session_destroy(&session)

for !gfx.WindowShouldClose() {
	gfx_frame, acquired := gfx.begin_frame()
	if !acquired do continue
	frame := ui_gfx.session_begin_frame_context(&session, &gfx_frame)
	draw(frame)
	ui_gfx.session_end_frame_context(&session, &gfx_frame)
	gfx.end_frame(&gfx_frame)
	free_all(context.temp_allocator)
}
```

Use `session_runtime`, `session_frame`, `session_input`, and `session_output` only
when host policy needs those values. Use `session_set_user_scale` instead of
mutating runtime scale state independently. Direct `adapter_*` lifecycle calls
are reserved for backend implementation and tests.

`App_Session_Config`, `App_Session`, and `app_session_*` are compatibility
aliases introduced before `v0.1.1`. They remain available through `v0.2.x` and
are removed in `v0.3.0`, providing one minor-release migration window. New code
uses `Session_Config`, `Session`, and `session_*`.

## Ownership and teardown

The shell enforces this order:

1. Acquire the graphics frame.
2. Open the UI session frame.
3. Invoke application drawing.
4. Finalize semantics and replay UI output.
5. Submit the graphics frame.
6. Reset temporary frame allocations.
7. On shutdown, invoke caller cleanup.
8. Destroy UI frame, adapter, and runtime through `session_destroy`.
9. Close the graphics context.

No active application or frame is exposed through `ui`; callbacks always receive
their owners explicitly.

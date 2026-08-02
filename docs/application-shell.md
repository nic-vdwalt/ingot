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
		{ui = draw, shutdown = shutdown},
		&state,
	)
}
```

The default UI callback receives the explicit app and the shell-owned open
`Ui`; the shell closes it after the callback. Use a `frame` callback instead
when the application owns explicit geometry or mixes direct graphics work. A
callback set must provide exactly one of `ui` or `frame`. The shutdown callback
runs while the graphics context is valid, so it must destroy caller-owned
textures, input boxes, builders, and components there.

On native targets, accepting an OS close request hides the window immediately,
then `app_run` remains blocked while shutdown and framework teardown run
synchronously. Shutdown code retains a valid graphics context but must not
expect another visible frame. The native window is destroyed after cleanup.
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
| Canvas inside flow layout | `canvas` callback plus `*_at` inside it |
| Manual canvas, scrolling, and overlays | `canvas_begin`/`canvas_end` and explicit geometry |
| Interactive facade widget | stable string/u64 key or explicit `Widget_Id` |

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
7. On a native OS close request, hide the native window.
8. Invoke caller cleanup while the graphics context remains valid.
9. Destroy UI frame, adapter, and runtime through `session_destroy`.
10. Close the graphics context and destroy the native window.

No active application or frame is exposed through `ui`; callbacks always receive
their owners explicitly.

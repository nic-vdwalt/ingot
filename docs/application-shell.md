# Fit application shell

`fit.App` is the supported one-window UI host. The caller owns the `App`,
application state, and persistent widget state. `fit.Run` owns window creation,
input capture, UI frame lifetime, layout rendering, accessibility publication,
graphics submission, frame scratch reset, and teardown ordering.

```odin
app: fit.App

main :: proc() {
	_ = fit.Run(
		&app,
		{
			width = 960,
			height = 640,
			title = "App",
			frame_pacing = .Monitor_Refresh,
			target_fps = 60,
			session = {semantics_enabled = true},
		},
		Draw,
	)
}
```

`Draw` receives an open `fit.Builder` and declares exactly one root. Layout
constructors return current-build `fit.Parent` values; child containers and
leaves consume those values, so prepared layout requires no balancing calls.
`fit.Center` creates a full-window centered root and `fit.Canvas` owns a
full-window explicit-geometry root. The shell renders the description after the
callback returns.

For a manually coordinated native host, use `fit.Init`, `fit.Start`, one bounded
`fit.Tick` per host iteration, `fit.Stop`, and `fit.Destroy`. `fit.Set_Theme` and
`fit.Set_Scale` update shell-owned runtime policy without exposing the runtime.

## Existing raylib loops

`fit.Session` adds the same builder to the default raylib context without
exposing graphics frames, UI frames, adapters, input snapshots, or output
buffers.

```odin
session: fit.Session

Frame :: proc() {
	_ = fit.Session_Draw(&session, Draw)
}

Draw :: proc(builder: ^fit.Builder, user_data: rawptr) {
	_ = user_data
	root := fit.Column(builder)
	fit.Label(root, "Custom loop")
}
```

`Session_Draw` returns false when no graphics frame was acquired. On success,
the builder is borrowed only for the callback; the session renders the declared
root, finalizes semantics and platform output, submits graphics, invalidates the
frame, and resets temporary storage before returning.

## Internal ownership

The implementation still separates application policy, UI session state, and
the renderer/platform adapter. Those boundaries keep headless UI tests, input
snapshotting, accessibility, text measurement, and replay independently
verifiable. They are not separate consumer integration levels.

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

`Draw` receives an open `fit.Builder`. It must declare exactly one balanced root
container. The shell renders that root and closes the hidden UI root after the
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
	builder, acquired := fit.Session_Begin(&session)
	if !acquired do return
	fit.Column(builder)
	fit.Label(builder, "Custom loop")
	fit.End(builder)
	fit.Session_End(&session)
}
```

`Session_Begin` may report that no frame was acquired. On success, the returned
builder is borrowed until `Session_End`. `Session_End` renders the balanced root,
finalizes semantics and platform output, submits graphics, invalidates the frame,
and resets temporary storage.

## Internal ownership

The implementation still separates application policy, UI session state, and
the renderer/platform adapter. Those boundaries keep headless UI tests, input
snapshotting, accessibility, text measurement, and replay independently
verifiable. They are not separate consumer integration levels.

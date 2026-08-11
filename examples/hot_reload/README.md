# Ingot hot reload

This native example keeps the Ingot window, WebGPU context, and `ui_gfx.Session`
in a persistent host while application state and immediate-mode UI code live in
a reloadable shared library.

## Run

macOS or Linux:

```sh
bash examples/hot_reload/build.sh run
```

Windows:

```bat
examples\hot_reload\build.bat run
```

While the window is open, edit `examples/hot_reload/game/game.odin` and run the
same build script without `run`. A successful build is published atomically and
the host loads it on the next frame. A failed build leaves the active library
running.

Click **Count persistent click** before rebuilding. The click count survives a
compatible reload and the reload generation increases.

## Boundary

`host/main.odin` owns every native and GPU lifetime. It watches `build/game`,
copies each build to a versioned filename, resolves the `game_*` ABI, and calls
the reloadable `game_draw` with the current caller-owned `ui.Ui_Frame`.

`game/game.odin` owns only `Game_State` and UI declaration. Mutable state that
must survive reload belongs in `Game_State`, not library globals. A reload reuses
state only when both `game_memory_size` and `game_memory_schema` match. Change
`GAME_STATE_SCHEMA` whenever a same-sized layout change is incompatible; size or
schema changes cause a safe state restart.

Old compatible libraries remain loaded because persistent state may contain
pointers into an earlier image. The example bounds this at 64 loaded versions;
restart the host after reaching that limit. Closing the window unloads all
versions and removes their copied files.

The example is native-only. Browser WASM modules use a different loading and
lifetime model.

## Origin

The architecture is adapted for Ingot from Karl Zylinski's
[Odin raylib hot-reload game template](https://github.com/karl-zylinski/odin-raylib-hot-reload-game-template).
The main difference is that Ingot's renderer and session stay entirely in the
host rather than crossing the shared-library boundary.

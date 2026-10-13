# Migrating from 0.3.3 to v0.4.0

The proposed source pin is `8cd2d9447d81139efd387be46378abefc6363fd0`.
`v0.4.0` deliberately uses a prefix absent from recent tags. Publication remains
pending; use the exact revision until the tag exists. This guide is post-pin
preparation, not a file contained in that snapshot. See the
[release ledger](releases/v0.4.0.md) for evidence and limitations.

## Upgrade checklist

1. Install the compiler recorded in `ODIN_VERSION`: `dev-2026-10:93f71c2`.
   Windows graphics-linked builds need `-linker:msvc` or `-linker:lld`.
2. Rename Fit procedure calls, preserving type and constant names.
3. Update mixed-layer values, named action fields and typed error handling.
4. Replace moved package imports and removed consumer gate invocations.
5. Review deferred-output ownership before adopting the new result APIs.
6. Compile your consumers and run application/native/web validation before
   changing their production pin. A source tag is not platform certification.

## Fit naming and boundaries

All public Fit procedures are snake_case with no PascalCase forwarders:
`fit.Run` becomes `fit.run`, `fit.Virtual_List_Begin` becomes
`fit.virtual_list_begin`, and `fit.Fixed` becomes `fit.fixed`. Arguments are
unchanged by the rename. A search for `fit\.[A-Z]` finds candidates, but also
finds valid types and constants: do not globally lowercase its matches.

`ui.Fit_Action.userdata` becomes `user_data`, including named struct literals
and field accesses. `fit.action` callers are unchanged.

Shared value vocabulary such as `fit.Rect`, `Color`, `Track`, and `Action`
remains aliases. At this exact candidate, prepared layout and widget options
also alias their reviewed UI definitions, including `Container_Options`,
`Size_Options`, `Button_Options` and `Control_Options`. Earlier Unreleased notes
incorrectly described these options as separate projections. Host/lifecycle
wrappers and enums remain separate where declared that way. Construct the
receiving layer's declared type at those boundaries; do not assume all Fit
values are interchangeable or invent an undocumented converter.
Applications staying entirely within Fit retain their Fit literals.

The no-forwarder rename is an explicit exception for this release, not a new
promise that arbitrary future removals will skip the compatibility window.

## Typed operating errors

| Operation | Current result | Migration |
| --- | --- | --- |
| `prefs.data_dir`, `prefs.path` | `(string, Prefs_Error)` | Replace success-bool checks with `err == .None` |
| `prefs.read` | `([]u8, Prefs_Error)` | Treat `.Missing` separately from `.Read` |
| `prefs.write` | `Prefs_Error` | Handle every non-`.None` result |
| `pty.spawn`, `pty.spawn_argv` | `(Pty, Spawn_Error)` | Check `.None` before using the PTY |

Preferences use the same signatures on native and web. `Prefs_Error` includes
`None`, `No_Data_Dir`, `Invalid_Name`, `Create_Dir`, `Open`, `Write`, `Missing`,
and `Read`. A missing preference can select defaults; unreadable data should not
silently be treated as a successful read.

`Spawn_Error` includes `None`, `Invalid_Args`, `Fork`, `Master_Setup`, `Exec`,
and `Unsupported`. Unix exec failure exits the child rather than synchronously
returning `.Exec`; Windows can report process-creation failure as `.Exec`.
`term.term_start` and `term.term_start_argv` optionally accept a
`spawn_error: ^pty.Spawn_Error` output when returning `nil`.

Existing application lifecycle booleans remain. Inspect `fit.last_error` and
`fit.last_graphics_error` (or the corresponding `ui_gfx`/`gfx` accessors) for
recorded failure reasons. `session_draw` returns `false` when it cannot acquire
a graphics frame and does not invoke the draw callback; this does not stop
`app_tick`, and a successful submission does not prove presentation.

## Package and tool moves

`ingot:asset`, `ingot:ecs`, `ingot:mesh`, `ingot:noise`, `ingot:scene`, and
`ingot:scene_gfx` move to `forgecore:<name>`. Register the receiving checkout
with `-collection:forgecore=<forgecore>`. Package names and public symbols are
unchanged by the move. Pin a compatible forgecore checkout separately; this
release does not establish one for you. Mesh cooking/export tools and their
related documentation move with those packages.

`ingot:box3d_workers` becomes `ingot:examples/box3d_workers`; its JS support
remains under `web/`. It is a WASM-only example bridge, not a new native API.

| Removed Python entry point | Replacement rule |
| --- | --- |
| `check_odin_style.py` | `odingate style` |
| `check_assertions.py` | `odingate assertions` |
| `check_ui_api_layers.py` | `odingate ui-api-layers` |
| `check_gfx_context.py` (internal) | `odingate gfx-context` |
| `check_init_order.py` (internal) | `odingate init-order` |

Build `tools/odingate` with the pinned compiler and the Ingot collection, then
invoke the rule with `--root <root> --files-from <list>`. The shell wrapper
`scripts/odingate.sh` provides `ingot_build_odingate` and
`ingot_odingate_files`. `scripts/consumer-contract.json` preserves these
consumer flags: style `--baseline`/`--print-procedures`; assertions
`--packages`/`--baseline`/`--measure`; ui-api-layers
`--consumer-root`/`--binding-allow`. AST-based checks can expose risks missed by
the previous textual scanner; review findings rather than expanding baselines
blindly. Internal rules are not additional promised consumer interfaces.

## Results and command ownership

Builder-owned `button_result` reports `Unavailable` or `Available` plus
`activated`. Poll the previous build's result using the same scoped identity;
results expire after one build. Storage is bounded, can be supplied externally,
and drops are observable through `button_results_dropped`.

Prefer builder-aware `typed_commands_begin(&queue, builder)`, then take the
available commands, declare buttons and call `typed_commands_end`. Collection
uses builder identity, owner epoch and the preceding generation, rather than
render-time pointers into queue activation fields. Keep the queue across builds
when delivery is needed. `typed_commands_end` discards untaken entries in its
begin-time snapshot while preserving newly appended commands. Handle
`button_command` saturation (`.Full`); its return is delivery acceptance, not
button activation. See [the runnable example](../examples/typed_commands/main.odin).

Actions, raw outputs and one-argument legacy queue begin remain supported.
Legacy activation slots must survive build and render until next collection;
raw `button_output` destinations must also outlive rendering. Value copies do
not own referenced payloads, strings or application models. Conflicting button
delivery options are rejected. Do not rename type names while migrating these
calls, or confuse `button_delayed` Signal delivery with owned polling.

## Known release limits

The pinned Windows libvterm archive remains unpatched; rebuild it from current
vendored sources with `scripts/build-libvterm.bat` before relying on those fixes.
CI tests a rebuilt replacement, not proof of the committed archive's behavior.
A corrected committed archive is separate follow-up work.

Keep the documented compiler crash-retry limitation visible. No regression,
Windows/Linux CI, GPU, accessibility or browser success is implied by this guide.
See [testing](testing.md), [dependencies](dependencies.md), and the
[release ledger](releases/v0.4.0.md) before shipping.

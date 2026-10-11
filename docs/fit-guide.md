# Fit: explicit state, simple composition

Start with `ingot:fit`: `run` owns the host, its `Draw` callback receives a
Builder, and containers return current-build Parents. Use ordinary procedures
for components. No retained behavioral widget tree or binding layer is needed.
See the [minimal application](../README.md#quick-start).

```odin
Draw :: proc(builder: ^fit.Builder, user_data: rawptr) {
	data := cast(^State)user_data
	root := fit.center(builder, {gap = .SM, padding = .LG})
	fit.label(root, "Settings")
	fit.button(root, "save", "Save", fit.action(Save, data))
}
```

`State` and `Save` belong to the application. Pass `&state` to `run`; check its
boolean result. A raw callback context is an explicit borrowed pointer, not a
closure allocation. Keep its cast at the callback boundary.

## Choose an interaction path

Prefer `typed_commands_begin(&commands, builder)` with `button_command` for
operations. Rendering retains neither the queue nor a callback context. For
polling, declare a plain button and query `button_result(parent, key)` next build.
Persistent value pointers remain necessary for checkboxes and sliders.
Actions are an advanced borrowed-context compatibility path:

```odin
fit.button(root, "save", "Save", fit.Button_Options{
    style = .Secondary,
    action = fit.action(Save, state),
})
```

Use `button_output(parent, key, label, &state.activated, options)` only when an
integration needs a deferred raw output. It accepts string, u64, and Widget_Id
keys. Its options must not also supply `activated` or an Action. Existing
`button(..., ^bool)` overloads remain compatibility-supported without warnings.
The default button style remains Primary.

Choose `button_delayed` for a later-build Signal, typed commands for shared
command processing, and Surface/Region controls for explicit geometry. These
are different timing contracts, not interchangeable spellings.

## Owned result polling

`button_result(parent, key)` accepts string, u64, and explicit Widget_Id keys.
Its value contains `status` (`Available` or `Unavailable`) and `activated`.
Queries are repeatable throughout the next build, not consuming reads. History
expires at the following begin; skipped renders and lifecycle/storage resets
produce `Unavailable`. Completed history with no activation yields an available
false. Overflow preserves recorded positives but makes unknown negatives
unavailable. Inspect `button_results_dropped(builder)` and
`typed_commands_unavailable(&queue)`; counters persist across ordinary resets.

`Storage.results` optionally supplies two equal ID banks: allocate twice the
wanted result capacity, at most twice `STORAGE_NODE_HARD_MAX`. It must remain
stable through every use. Without it, the builder uses inline bounded storage.
Scoped keys isolate components; explicit IDs are unchanged. Reusing an ID means
the same logical button: use generation-bearing entity keys for replacements.
This does not validate object lifetimes. Command payload copies are shallow;
prefer enums, owned value records, or validated handles rather than borrowed
strings, slices, or pointers. Custom userdata and editable model pointers remain
borrowed. See `examples/typed_commands` for scoped polling and safe commands.

## When state changes

```text
input -> Draw builds description -> measure/layout/render
      -> activated Actions dispatch -> finalize/redraw request
      -> next required Draw observes the new application state
```

Builder declarations do not execute interactions inline. Pointer-bound controls
update their destinations during rendering. Actions run once in the activating
frame, after description construction, in declaration traversal order. Neither
can change the already-built description. Do not call Draw twice to simulate
synchronous interaction; preserve bounded work and event-driven sleep.

| Mechanism | Delivery | Ownership / recommendation |
|---|---|---|
| `button` + `action` | Activating render, after declaration | Advanced compatibility; caller owns context through dispatch |
| Checkbox/slider value pointer | During rendering | Default for a value; caller owns backing storage |
| `button_delayed` + `Signal` | Observed/consumed by a later build | Optional one-shot latch; caller owns Signal |
| `button_command` | Collected at next `typed_commands_begin` | Recommended with builder-aware begin; bounded value commands |
| Surface interaction return | Inside its render callback | Advanced explicit-geometry code; Surface is borrowed |

A later declaration in the same Draw still reads pre-render state. See
`fit/fit_test.odin` for pointer Action and Signal timing, and
`fit/dx_contract_test.odin` for keyboard and pointer-bound-value contracts.

## Lifetimes are part of the interface

| Value | Required lifetime |
|---|---|
| Application / widget state | Feature lifetime, including frames when not displayed |
| Parent | Only the build that created it; never store it in application state |
| Surface | Only its render callback; never retain it |
| Control destination / Action context | Through rendering and dispatch, not just the declaring helper |
| Borrowed labels, tracks, item slices | Through their current-build consumers |
| Typed queue activation slots | Through render and collection on the following build |

Do not pass a component helper's local bool or stack-local callback context to a
Builder control. The helper returns before rendering. Use fields of the
caller's persistent component state instead. Copied structs containing slices
or pointers do not deep-copy their backing storage.

### Lifetime and visibility are separate

This helper is invalid under the default deferred rendering path:

```odin
invalid_helper :: proc(parent: fit.Parent) {
    activated := false
    fit.button_output(parent, "save", "Save", &activated)
}
```

The helper returns before the destination is written. Instead, keep the value
in persistent component state:

```odin
draw_save_output :: proc(parent: fit.Parent, state: ^Save_State) {
    fit.button_output(parent, "save", "Save", &state.activated)
}
```

`Save_State` owns an `activated: bool` field and must survive rendering. Reading
that field immediately after declaring the button still reads pre-render state.
For an operation, prefer builder-aware typed commands instead of polling this output.

Actions also borrow their context; they do not create owning closures. Strings,
item slices, and track slices borrow backing storage: copying their descriptors
is not a deep copy. Explicit `render` consumes declarations synchronously, but
is not the recommended workaround for helper-local pointers. Never call Draw
twice to imitate immediate interaction.

## Reusable components

The runnable `examples/builder_controls` uses this recipe:

```odin
draw_preference :: proc(parent: fit.Parent, stable_key: u64, data: ^Workspace_Preference) {
	assert(data != nil, "builder controls preference: nil state")
	assert(stable_key != 0, "builder controls preference: zero key")
	scoped := fit.scope(parent, stable_key)
	fit.checkbox(scoped, "enabled", "Enable local settings", &data.enabled)
}
```

The application stores each `Workspace_Preference` and supplies its stable domain
key. `scope` changes identity without adding layout. Ordinary Row/Column nesting
does not create identity scopes. Local keys can repeat across scoped components;
labels are presentation, not identity. Do not derive keys from list position,
addresses, or source locations. Reordering changes placement, not ownership.

Group values and interaction state under the feature owner: a boolean needs no
cleanup; a combobox's interaction state does. The example's `destroy_state`
pairs resource-bearing cleanup with application ownership. Headless tests call
it explicitly and use Odin's test memory tracker.

The example uses `run`: native return ends its application lifetime, so cleanup
runs there. In the browser, `run` returns after asynchronous startup; state remains
live, and native post-`run` cleanup must not execute then. An embedding that removes
or replaces browser applications must use an explicit host lifecycle and its
shutdown callback to call its owner cleanup; page-lifetime globals are not a
reusable multi-app teardown recipe. See [application shell](application-shell.md).

### Tagged operations on generated components

`examples/builder_controls` pairs `draw_preference_reset` with `reset_preference`:

```odin
scoped := fit.scope(parent, stable_key)
fit.button(scoped, "reset", "Reset local settings",
    fit.action(reset_preference, data, stable_key))
```

The tag is copied by value; `data` remains a borrowed persistent owner. The
callback looks up the component by stable key, resets only its value, and safely
ignores a removed key. It does not capture a pointer to a loop-local item or
replace resource-owning widget state. Reordering keys and their corresponding
state together preserves the target. The example tests cover pointer/keyboard
activation, post-declaration dispatch, and isolation after reorder/removal.

## Optional typed commands

Handle `button_command` results: `.Full` means no button was declared, so layout
and focus order exclude it. Previously accepted controls remain usable. Keep the
queue across builds to preserve command values. In builder-aware mode widgets
retain no queue pointers. The legacy one-argument begin still borrows activation slots. Do not provide Action or raw-output delivery fields
in command-button options. See [Commands](commands.md) for capacity semantics.

Use `Typed_Commands(T, Capacity)` with `typed_commands_begin(&queue, builder)`
as the default operation path. Reset before switching between owned and legacy
modes. The capacity is fixed and shared with the bounded drain loop.

```text
Draw N:
  Begin: collect prior render's activations; freeze drain limit
  drain at most Capacity values into application state
  declare Button_Command controls while collection is open
  End (deferred until Draw returns)
Render N: record activated button IDs in builder-owned history
Draw N+1: resolve descriptors against that history
```

`examples/typed_commands/main.odin` is the executable recipe. Pair Begin with
`defer Typed_Commands_End` immediately, not End before declaring buttons.

- `.Accepted` means an activation slot was reserved, not that a click occurred.
- `.Full` means no control was declared by that call. Handle it without automatic
  growth or retries. The example displays failure/drop status on the next build.
- `typed_commands_dropped` reports ready and activation saturation separately;
  Reset clears pending work but preserves these counters.
- Begin freezes the drain. Entries appended afterwards wait for a later drain.
- End discards unread entries in the frozen drain, retaining post-snapshot
  entries. Drain the complete bounded snapshot when every command matters.
- `T` is copied by value. Its pointer/slice fields retain caller lifetime duties.

The example tests invoke its actual Draw, activate via keyboard, collect on the
following build, and exercise saturation. `fit/typed_command_test.odin` covers
FIFO, partial drains, capacity boundaries, and persistent drop diagnostics.

## When the shell fails

Every `fit` lifecycle procedure returns a plain `bool`; the reason lives on the
app. After a false `fit.run`, `fit.init`, `fit.start`, `fit.stop`, or
`fit.destroy`, read `fit.last_error` (a `fit.Error`: `.Invalid_State`,
`.Context_Not_Live`, `.Graphics`, or `.Close_Refused`) and, for the graphics
cases, `fit.last_graphics_error` (a `fit.Graphics_Error` such as `.Adapter` or
`.Device`). `examples/hello` prints both when `fit.run` fails. A refused destroy
leaves the app intact so the call can be retried.

## Test and diagnose without a window

Use `test_driver_init`, `test_driver_frame`, and `test_driver_destroy` with the
same Draw and caller state used by the app. Enable semantics explicitly with
`test_driver_set_semantics`. Test input sequences, not only one successful frame.

After each frame inspect `test_driver_diagnostics`, `test_driver_paint_summary`,
`test_driver_redraw_requested`, and, when telemetry is enabled,
`test_driver_telemetry`. Successful frame execution does not mean zero drops.
A duplicate focus ID is programmer misuse and can assert before a semantic
snapshot is produced; semantic collision counters are not universal ID checking
when semantics are disabled. The DX tests deliberately inject duplicate semantic
records separately from focus registration to verify bounded degradation.

Duplicate-focus assertions include the stable focus ID and the first/current
registration indices. These are traversal indices, not declaration source lines.
Prepared-node exhaustion includes the requested parent, current count, and capacity.
Both messages remain assertion-only programmer-error diagnostics, not recovery APIs.

Fit's internal diagnostic tests compare an explicit expected snapshot across every
counter. Omitted expected fields mean zero; intentional degradation must be named.
Failures identify the counter, expected/observed counts, frame index, and seed.

| Symptom | Check |
|---|---|
| Stale Parent assertion | Rebuild Parent each Draw; never cache it |
| Duplicate stable ID | Scope repeated components using domain keys |
| State appears one build late | Distinguish declaration from render/dispatch |
| Queue Full or missing button | Handle reservation result; inspect both drop counters |
| Missing/clipped output | Inspect layout/paint drops and balanced clip scopes |
| Double-scaled geometry | Layout callback rectangles are already physical |
| Idle redraw work | Check action/redraw output instead of continuously rebuilding |

## Small custom-geometry islands

`examples/builder_controls/custom_preview.odin` is a `canvas_leaf` render
callback beside ordinary controls. It receives a borrowed Surface and physical
rectangle, brackets clipping, resolves colors from theme tokens, and uses `px`
only for a logical inset constant. It bounds the inset by the available rectangle.
It returns false because painting the preview does not activate a control.

Do not scale the callback rectangle again. Keep custom geometry local rather
than converting the whole form to Surface or retaining a second scene tree.
Headless tests exercise the account tab at DPI 1 and 2 and check clip balance and
drop counters. An isolated preview fixture also checks both emitted rectangles
against the physical callback bounds and the Surface-resolved inset. These are
not evidence of GPU pixels or assistive-technology behavior.

## Verification

Use the compiler pinned by `ODIN_VERSION`; see [testing](testing.md) for gates.

```sh
odin test fit -collection:ingot=. -define:ODIN_TEST_THREADS=1
odin test examples/typed_commands -collection:ingot=. -define:ODIN_TEST_THREADS=1
odin test examples/builder_controls -collection:ingot=. -define:ODIN_TEST_THREADS=1
```

Safety, bounded work, explicit lifetime, and inspectable output stay ahead of
convenience. This guide adds no framework-owned state or production API.

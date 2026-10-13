# Consumer API baseline

The supported UI baseline is one import and one declaration model.

| Scenario | Imports | Visible lifecycle | Declaration API |
|---|---:|---:|---|
| One-window UI app | 1 (`ingot:fit`) | `run` | `fit.Builder` |
| Explicit app ticking | 1 (`ingot:fit`) | `init`, `start`, `tick`, `stop`, `destroy` | `fit.Builder` |
| Existing raylib loop with UI | 2 (`ingot:gfx`, `ingot:fit`) | `session_init`, `session_draw`, `session_destroy` | `fit.Builder` |
| Graphics-only raylib migration | 1 (`ingot:gfx`) | raylib-compatible lifecycle | snake_case `gfx` |

Application code does not own `Ui_Runtime`, `Ui_Frame`, `Ui_Output`, `Adapter`,
`Prepared_Ui`, or graphics `Frame` values. Compile coverage for the public UI
contract lives in `fit/fit_test.odin`; renderer-independent engine behavior
remains covered by `ui` tests. Scoped composition, explicit identity scopes,
and native controls use the same borrowed `fit.Builder`; they do not establish
another lifecycle or declaration object.

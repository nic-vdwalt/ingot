# Consumer API baseline

The supported UI baseline is one import and one declaration model.

| Scenario | Imports | Visible lifecycle | Declaration API |
|---|---:|---:|---|
| One-window UI app | 1 (`ingot:fit`) | `Run` | `fit.Builder` |
| Explicit app ticking | 1 (`ingot:fit`) | `Init`, `Start`, `Tick`, `Stop`, `Destroy` | `fit.Builder` |
| Existing raylib loop with UI | 2 (`ingot:gfx`, `ingot:fit`) | `Session_Init`, `Session_Begin`, `Session_End`, `Session_Destroy` | `fit.Builder` |
| Graphics-only raylib migration | 1 (`ingot:gfx`) | raylib-compatible lifecycle | PascalCase `gfx` |

Application code does not own `Ui_Runtime`, `Ui_Frame`, `Ui_Output`, `Adapter`,
`Prepared_Ui`, or graphics `Frame` values. Compile coverage for the public UI
contract lives in `fit/fit_test.odin`; renderer-independent engine behavior
remains covered by `ui` tests. Scoped composition, explicit identity scopes,
and native controls use the same borrowed `fit.Builder`; they do not establish
another lifecycle or declaration object.

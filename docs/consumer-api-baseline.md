# Consumer API baseline

This baseline records source-level ceremony before the additive API cleanup. The
compile-only coverage lives in `ui/consumer_api_test.odin`; the application host
and custom-host paths are covered by `examples/hello` and
`ui_gfx/session_test.odin`.

| Scenario | Imports | Lifecycle calls | Identity calls | Widest widget call | Cleanup calls |
|---|---:|---:|---:|---:|---:|
| Minimal `App` (`examples/hello`) | 3 | 1 | 8 | 5 arguments | 0 |
| Form (`consumer_api_test`) | 1 | 4 | 6 | 6 arguments | 3 |
| Repeated-ID list (`consumer_api_test`) | 1 | 0 additional | 5 | 3 arguments | 0 additional |
| Canvas region (`consumer_api_test`) | 1 | 2 | 0 | 3 arguments | 0 |
| Custom `Session` (low-level) | 3 | 5 | 0 | 3 arguments | 2 |
| Custom `Session` (capability) | 3 | 3 | 0 | 3 arguments | 1 |

“Lifecycle calls” counts explicit begin/end or run/init operations visible to the
consumer. “Identity calls” counts `id`, `scope_begin`, and `scope_end`. The
baseline is intentionally mechanical: an additive API change is worthwhile only
when it lowers these counts without hiding ownership, bounds, or failure modes.
Capability presentation owns graphics submission and temporary-frame cleanup.

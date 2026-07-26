# ingot — Agent Guide

`ingot` is an Odin-first, immediate-mode app/engine on WebGPU. One source runs
natively (macOS/Metal, Windows/D3D12, Linux/Vulkan) and in the browser (WASM +
WebGPU). Native terminal and accessibility bindings use vendored libraries. See
`README.md` for the project overview, `docs/immediate-mode.md` for the
architecture, and `docs/testing.md` for the test matrix.

## Packages

| Package          | Role |
|------------------|------|
| `ingot:gfx`      | graphics core (raylib-shaped): window/context, 2D shapes, textures, text atlas, input, math, cameras, `rlgl` shim |
| `ingot:ui`       | renderer-independent immediate-mode toolkit: widgets consume `Ui_Input` and append bounded paint, semantics, and platform output. It must not import `ingot:gfx`. |
| `ingot:ui_gfx`   | bridge that snapshots `gfx` input, replays UI paint, manages UI fonts, and applies platform output |
| `ingot:prefs`    | per-app settings persistence (native file / web `localStorage`) |
| `ingot:net`      | background HTTP `Fetcher` + self-healing RFC 6455 `WebSocket` client |
| `ingot:sys`      | system integration: URLs, cache paths, and native dialogs |
| `ingot:term`     | terminal core: libvterm + PTY, per-frame pump, key→VT translation |
| `ingot:libvterm` | Odin bindings for libvterm 0.3.3 (prebuilt static libs committed) |
| `ingot:accesskit` | Odin bindings for the native AccessKit C API |
| `ingot:pty`      | PTY: `forkpty` (unix) / ConPTY (Windows) |
| `ingot:testx`    | deterministic PRNG and snapshot test helpers |

## Build / test / check commands

- **Register the collection** when building a consumer:
  `odin build src -collection:ingot=libs/ingot`
- **Test**: `bash scripts/test.sh` — runs `odin test` on `gfx ui ui_gfx
  libvterm term prefs net`, then type-checks `sys pty accesskit testx`. Python 3
  supervises each command. Pass extra Odin flags through, e.g.
  `bash scripts/test.sh -define:ODIN_TEST_THREADS=1`.
- **Check / lint** (Tiger Style gate): `bash scripts/check.sh` — strict
  type-check + `-vet -strict-style -vet-shadowing`, 70-line procedure and
  100-character physical-line checks, plus an `odinfmt` format check.
- **Format**: `odinfmt -w .` (settings pinned in `.odinfmt.json`: tabs width 4,
  100-column lines).
- **Web build**: `bash build_web.sh` → `web/ingot_web.wasm`; serve with
  `(cd web && python3 -m http.server 8000)`.
- **Web gate**: `bash scripts/check-web.sh` — compiles gallery, Breakout, and the
  default demo, then runs `web/test/*.test.mjs` with dependency-free Node.
- **Rebuild libvterm** (rarely needed): `scripts/build-libvterm.sh` (macOS) /
  `scripts/build-libvterm.bat` (Windows).

## Coding style — Tiger Style

`ingot` follows **Tiger Style** (adapted from TigerBeetle). Read
[`docs/TIGER_STYLE.md`](docs/TIGER_STYLE.md) before contributing. The
non-negotiables:

- **Safety > performance > developer experience**, in that order. Zero technical
  debt — fix showstoppers in design, not production.
- **Assertions catch programmer errors** (not operating errors — a closed PTY, a
  dropped socket, and a missing file are *handled*, not asserted). Average **≥ 2
  assertions per procedure**: assert arguments, return values, pre/postconditions,
  and invariants. Use `assert` for debug checks, `ensure` for release-kept checks
  on untrusted input, `#assert` for compile-time constant/size checks. **Pair
  assertions** across a boundary (validate before write and after read).
- **No recursion. Put a limit on everything** — every loop and queue has a fixed
  upper bound (see `term.TERM_PUMP_MAX_BUFS`) or an asserted exit invariant.
- **Immediate-mode / static allocation**: callers own state and pass it each
  frame; allocate long-lived buffers once; use `context.temp_allocator` for
  per-frame scratch.
- **Explicit sized types** at wire/file/FFI boundaries (never `int`/`uint`
  there); keep `index` / `count` / `size` distinct.
- **Handle every returned `ok` / error** — no silent `or_return` drops.
- **70 lines per procedure, 100 columns per line, tabs width 4.** Run `odinfmt`.
- **Always say why** in comments — full sentences. The UTF-8 hold-back note in
  `term/term_pump.odin` is the bar.

**Rollout policy:** new and changed procedures must carry their assertions and
stay within the length/width limits. Existing code is upgraded to the standard
when it is next touched — improve on contact, don't mass-rewrite.

`term/term_pump.odin` (`term_pump`) carries worked-example assertions to copy.

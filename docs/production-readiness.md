# Production readiness

This document records the security and platform-validation boundary for `ingot`.
It is a release checklist, not a claim that every listed target has already been
validated. Passing package tests proves deterministic core behavior; it does not
by itself prove Internet transport, operating-system integration, browser, GPU,
or assistive-technology behavior on every supported platform. See
[Compatibility and platforms](compatibility.md) for supported API behavior and
[Networking](networking.md) for lifecycle and ownership.

## Networking

Use `http_request_url` for general Internet HTTP. It parses explicit `http` and
`https` URLs, rejects control characters, user information, malformed ports, URL
fragments, and secure-to-plaintext redirect resolution. Native URL requests use
libcurl with peer-certificate and hostname verification explicitly enabled. The
legacy host/port HTTP and WebSocket APIs remain plaintext compatibility paths and
must not carry credentials or confidential data.

Native WebSocket client masking keys and handshake nonces use operating-system
cryptographic entropy. Incoming server frames reject masking, reserved extension
bits and opcodes, noncanonical lengths, invalid control-frame fragmentation, and
oversized control payloads. Receive queues are bounded by both message count and
aggregate bytes. Browser bridges impose the same message and queue ceilings and
select secure schemes for port 443.

Browser networking remains subject to the browser security model: CORS, forbidden
headers, ambient credentials, mixed-content policy, and browser-managed certificate
validation are not overrideable by Odin code.

## Graphics ownership

The PascalCase raylib-shaped API uses `gfx.default_context()` for compatibility.
Every context has a monotonically increasing lifecycle epoch. Frames, asynchronous
WebGPU adapter/device completion, and submission callbacks validate that epoch so
work from a closed lifetime cannot mutate a replacement lifetime.

`ui_gfx.Adapter` records its graphics context and epoch at initialization,
rejects stale use, and can bind an explicit graphics frame. Native contexts own
independent windows, renderers, resources, input, timing, statistics, and
submission tracking; explicit frames route rendering through their recorded
owner. The PascalCase API remains a default-context facade. Parallel renderer
threads and browser multi-canvas hosting remain outside the production guarantee.

## PTY and terminal

PTY dimensions are nonzero and capped at 32767 before Unix or ConPTY conversion.
Unix login names reserve their terminator byte, nonblocking setup failures abort
spawn, interrupted reads are retryable, and write procedures report partial I/O and
status. Terminal input retries bounded partial writes and caps clipboard pastes at
1 MiB.

The ordinary terminal suite uses the deterministic PTY simulator and does not spawn
a shell. Real Unix PTY and Windows ConPTY behavior requires the platform integration
matrix below, including process-group teardown, child reaping, resize propagation,
final-output drain, and descriptor/handle leak checks.

## System integration

`open_url` accepts only explicitly enabled `http`, `https`, and `mailto` schemes,
rejects control characters and overlong values, and reports dispatch failure.
Cache application identifiers are bounded path components and environment-provided
cache roots must be absolute. Dialog inputs use recoverable length validation.
Selected paths remain untrusted application input and must be opened with normal
filesystem permission, symlink, type, and size checks.

## Browser lifecycle

Input attachment tracks held keys and pointer buttons and releases them on pointer
cancellation, lost capture, blur, visibility loss, replacement, and teardown.
Session cleanup is idempotent and isolates failures in application shutdown,
network cancellation, event detachment, and semantic-overlay removal. Asynchronous
audio loads are abortable when their slot is unloaded. WASM fetch failures include
non-success HTTP status.

Node DOM tests validate bridge state machines only. They do not replace a real
Chromium/WebKit run, screen-reader exercise, audio-unlock test, or WebGPU validation.

## Validation matrix

| Target | Mandatory automated checks | Required release validation | Status |
|---|---|---|---|
| macOS | Tests including loopback WSS, strict checks | Native trust-store WSS, real PTY, Metal, Safari, VoiceOver | Not recorded |
| Linux | Tests including loopback WSS, strict checks | Native CA-source WSS, real PTY, Vulkan | Not recorded |
| Windows | Native tests including loopback WSS, strict checks | Native trust-source WSS, ConPTY, D3D12/Vulkan, screen reader | Not recorded |
| Browser | `scripts/check-web.sh`, Node tests | Chromium and WebKit lifecycle/input/network/WebGPU runs | Not recorded |
| Internet TLS | URL/parser and loopback certificate tests | HTTPS/WSS valid, expired, untrusted, wrong-host, timeout, IPv4/IPv6, proxy, downgrade | Not recorded |

Record operating system, architecture, Ingot/Odin revision, browser, GPU, driver,
backend, date, commands, and outcome with `scripts/validation-evidence.py` and
`docs/validation/schema.json`. Generate matrix rows with
`scripts/validation-matrix.py`; missing evidence remains Not recorded. Use only
these status terms:

- `compiled` - source built for the target; runtime behavior is unverified.
- `validated` - the dated release fixture and platform checks passed without
  validation errors.
- `blocked` - the check could not run; record the missing hardware, dependency,
  credential, or platform capability.
- `failed` - the check ran and exposed a defect; link the reproducer or issue.

Do not infer `validated` from a build-only or Node-only result.

## Release gate

Before describing a revision as production-ready for a target:

1. Pin and record the exact Ingot and Odin revisions.
2. Run package tests, strict checks, and the web gate where applicable.
3. Run deterministic fuzz targets and TSan for networking/concurrency changes.
4. Run `fuzz/run.sh gfx-frame`, `examples/render_fixture`, and
   `examples/multi_context_fixture` for renderer changes.
5. Exercise lifecycle replacement and teardown, not only startup.
6. Complete the target's PTY, dialog, URL, accessibility, audio, input, and
   browser checks that the release actually exposes.
7. Record failures and blockers instead of silently omitting matrix entries.

## Remaining production work

- Native WSS has deterministic loopback coverage; revision-pinned macOS, Linux,
  Windows, proxy, IPv4/IPv6, and public-Internet evidence remains required.
- Native multi-context rendering requires representative Metal, D3D12, and
  Vulkan validation evidence; browser multi-canvas and parallel rendering remain
  separate future capabilities.
- Real PTY/ConPTY, native dialogs, accessibility, browser, and backend GPU jobs need
  representative hardware or virtualized runners.
- Strict CSP deployment and content-hashed browser assets remain packaging work.

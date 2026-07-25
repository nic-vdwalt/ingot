# Production readiness

This document records the security and platform-validation boundary for `ingot`.
Passing the package tests proves deterministic core behavior; it does not by itself
prove Internet transport, operating-system integration, browser, GPU, or assistive-
technology behavior on every supported platform.

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

`ui_gfx.Adapter` records its graphics context and epoch at initialization and
rejects stale use. The explicit binding is an ownership boundary; rendering still
routes through the default facade until all renderer/resource procedures accept a
context parameter. Multiple simultaneously rendering windows are therefore not yet
a production guarantee.

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

| Target | Mandatory automated checks | Required release validation |
|---|---|---|
| macOS | `scripts/test.sh`, `scripts/check.sh` | Real PTY, dialogs/URL, Metal fixture, Safari WebGPU, VoiceOver |
| Linux | `scripts/test.sh`, `scripts/check.sh` | Real PTY, dialogs/URL, Vulkan fixture on supported drivers |
| Windows | Native equivalents of test/check gates | ConPTY, dialogs/URL, D3D12 and Vulkan fixtures, screen reader |
| Browser | `scripts/check-web.sh`, Node tests | Chromium and WebKit lifecycle/input/network/WebGPU runs |
| Internet TLS | URL/parser unit tests | Valid chain plus expired, untrusted, wrong-host, timeout, IPv4/IPv6, and downgrade cases |

Record operating system, architecture, browser, GPU, driver, backend, and date for
manual release validation. A build-only result must be marked `compiled`, never
`validated`.

## Remaining production work

- Native WSS still requires a TLS-capable WebSocket transport; the compatibility
  socket implementation is plaintext.
- Full renderer multi-context routing and context-owned resource identity remain
  incomplete behind the explicit default-context facade.
- Real PTY/ConPTY, native dialogs, accessibility, browser, and backend GPU jobs need
  representative hardware or virtualized runners.
- Strict CSP deployment and content-hashed browser assets remain packaging work.

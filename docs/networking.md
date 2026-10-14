# Networking

`ingot:net` provides bounded HTTP and reconnecting RFC 6455 WebSocket clients on
native and web targets. The APIs share application-facing shapes, but transport,
security, caching, and wakeup behavior differ by platform.

## HTTP choices

Ingot's HTTP implementation is temporary and will be replaced when Odin provides
its proper HTTP package. This does not apply to Ingot's WebSocket client.

Use `http_request_url` for general Internet URLs. It accepts explicit `http` and
`https` schemes, validates redirects, and rejects user information, fragments,
control characters, malformed ports, and HTTPS-to-HTTP downgrade redirects.
Native HTTPS uses libcurl with certificate and hostname verification. Browser
requests use `fetch` and remain subject to CORS, forbidden-header, credentials,
mixed-content, redirect, and certificate policy enforced by the browser.

The host/port `http_request`, `http_get`, and `Fetcher` interfaces are legacy
compatibility paths. Native host/port traffic is plaintext. Do not send secrets,
tokens, or confidential content over it. On web, synchronous `http_request` is
unsupported; use `Fetcher` so work can complete through the host event loop.

Every request has a body ceiling. Zero selects `DEFAULT_MAXIMUM_BODY` (64 MiB).
Set a lower `maximum_body` for known payloads. Header parsing, chunk decoding,
redirects, receive calls, pending jobs, results, and drain counts are bounded.
Treat a `false` request result as backpressure or invalid input, not as a queued
operation.

## Fetcher lifecycle

A `Fetcher` owns cloned requests, queued work, in-flight transport state, and
undrained result bodies:

1. Zero-initialize the value.
2. Set optional fields such as `cache_validator` and native `wake` before start.
3. Call `fetcher_start` once with the host and port.
4. Submit requests and handle a `false` return without assuming completion.
5. Drain results regularly on the owning/application thread.
6. Call `fetcher_stop` before destroying dependent application state.

Native uses eight worker threads with at most 64 pending jobs and 64 total
result slots. A contextless `wake` hook such as `gfx.request_redraw` lets a worker
wake an event-driven frame loop after queueing a result. Web is single-threaded,
keeps at most six requests in flight, polls completions from the browser frame
loop, and never invokes the wake hook.

`fetcher_stop` cancels or closes in-flight work, joins native workers, and frees
jobs and results still owned by the fetcher. It does not free bodies already
transferred by `fetcher_drain`.

## Cancelling queued work

`fetcher_cancel(&fetcher, tags)` withdraws requests that are still queued and
returns the tags it actually removed (a `context.temp_allocator` slice). Their
result slots are released immediately and no `Fetch_Result` is ever delivered
for them. Requests a native worker has already started, or that the browser
backend has already handed to `fetch`, are not affected and still deliver a
result. Callers must therefore reset per-tag bookkeeping only for the returned
tags, never for the full input list. The simulated transport cancels any
undelivered message and counts it in `Sim_Stats.cancelled`.

Use it to drop work the application no longer needs, for example map tiles that
have scrolled out of view or belong to a zoom level the camera has left, so it
stops occupying the bounded queue ahead of work that is still wanted.

## Native connection reuse

Each native `Fetcher` worker keeps its connection open between jobs. It sends
`Connection: keep-alive` and reads exactly one framed response, using
`Content-Length`, chunked transfer encoding, or a bodiless 204/304 status. The
resolved host endpoint is cached on the fetcher, and a failed dial clears it so
the next dial resolves again.

- A response with no framing is read until the server closes, and that
  connection is not reused.
- A response carrying `Connection: close`, an HTTP/1.0 status line, or a read or
  parse error also closes the connection.
- A reused connection that fails before any response byte arrives (typically a
  server closing an idle keep-alive socket) is redialled and the request
  retried once. This applies only to idempotent methods. `Post` and `Patch`
  always use a fresh connection, so a request is never replayed after the
  server may have acted on it.
- `fetcher_stop` closes every worker connection, including idle ones.

The standalone host/port `http_request` and `http_get` still open one connection
per call and send `Connection: close`.

## Result ownership

The slice returned by `fetcher_drain` uses `context.temp_allocator` and is valid
only for temporary use. Each `Fetch_Result.body` transfers to the caller and
must be deleted exactly once after every borrowing consumer has finished:

```odin
for result in net.fetcher_drain(&fetcher) {
	if result.ok {
		consume(result.tag, result.status, result.body)
	}
	delete(result.body)
}
```

Delete the body even when `ok` is false; a failed status may still carry an
allocated response body. Copy a body before retaining it under a different
allocator or lifetime.

`Fetch_Options.priority` inserts work ahead of normal pending work; it does not
preempt an in-flight request. Native `cache_path` may read or write a caller-
selected file after `cache_validator` accepts it. The browser backend accepts
the field for API parity but does not provide filesystem caching. Build cache
paths from `sys.cache_dir`, keep them app-scoped, and treat cached bytes as
untrusted input.

## WebSocket lifecycle

A `WebSocket` reconnects after transient failures until its configured attempt
bound is exhausted or it is closed:

1. Initialize with `ws_init`.
2. Set the optional native `wake` hook before connecting.
3. Call `ws_start_connect_url` with an explicit `ws://` or `wss://` URL and bounded options.
4. Observe connection changes through `ws_state` and `ws_conn_gen`.
5. Send only while connected and handle a `false` send result.
6. Drain and free messages on the application thread.
7. Always call `ws_close` before releasing the value or dependent state.

`ws_conn_gen` advances after each successful handshake. When it changes,
re-establish server-side subscriptions because they belonged to the previous
socket. Native connection and receive work runs on a worker thread; state access
uses the provided procedures rather than direct field reads.

Native `wss://` uses libcurl TLS with peer-chain, hostname, and SNI validation.
Verification cannot be disabled. `WS_Options.ca_file` may add a private trust
root on native builds; browsers use browser-managed trust. Scheme, not port,
selects security. The legacy `ws_start_connect` API remains plaintext.

Certificate and configuration failures publish `.Error` and do not reconnect.
Transient connection and stream failures retain bounded reconnect behavior. Use
`ws_error` to inspect the last classified failure.

## WebSocket ownership and limits

`ws_drain` returns a temporary slice. Every `WS_Message.data` string is heap
allocated and owned by the caller; delete it exactly once after processing.
`ws_has_pending` can avoid unnecessary drains but does not transfer ownership.

Incoming frame sizes, fragmented messages, queued message count, and aggregate
queued bytes are bounded. When a queue is full, latest data wins and older
queued data may be discarded. Applications needing lossless delivery must add
an application-level acknowledgement/replay protocol rather than treating the
client queue as durable storage.

The native parser requires unmasked server frames, canonical lengths, valid
reserved bits/opcodes, bounded control frames, and valid fragmentation. Client
masking keys and handshake nonces use operating-system cryptographic entropy.
The browser supplies framing, TLS, and certificate validation.

## Event-driven applications

Set `Fetcher.wake` and `WebSocket.wake` to `gfx.request_redraw` before starting
native networking. Drain results/messages during the resulting frame and derive
UI state from them. Browser completions are polled by the active animation-frame
session, so the managed web session must remain alive until networking is
stopped and page teardown is complete.

## Testing

`bash scripts/test.sh` covers parsers, ownership, simulated transport, workers,
and an Internet-independent loopback TLS matrix. Deterministic `fuzz/run.sh net`
exercises HTTP and WebSocket parsing;
`fuzz/run.sh wsreconn` exercises reconnect synchronization; the TSan phase
covers WebSocket and HTTP worker concurrency. These do not replace real TLS,
proxy, CORS, DNS, timeout, IPv4/IPv6, browser, and unreliable-network testing in
the release matrix.

The simulation seams replace the network edge only. `INGOT_NET_SIM` and
`INGOT_WS_SIM` substitute a scripted transport that can produce dial failures,
handshake faults, fragmented or invalid frames, closes, cuts, and timeouts,
while the production worker thread, mutexes, atomics, condition variable,
bounded queue, and reconnect loop keep running unchanged. Networking is the
subsystem where real-world failure orderings are least reproducible and most
consequential, so scripting them from a seed converts a rare production race
into a replayable test. See [Testing Ingot](testing.md) for why this seam style is preferred over
mocking the client.

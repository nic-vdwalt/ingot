# Metal timing investigation: partial evidence, 2026-09-06

Status: subplan step 1 remains in progress. No timing repair or performance acceptance.

## Actual game evidence

Rebuilt Aesir's `scripts/capture_profile.odin` Watch/Recorder driver and current
PlanetForger profile host/library. First 30-second capture remained in loading,
produced an empty telemetry file and was stopped at the deadline. Its Aesir
recording is `artifacts/aesir-profile-1788700534-19261-313494554980583.jsonl`.
This is not evidence of healthy timing or normal shutdown.

A diagnostic-only build with `INGOT_GPU_TIMING_DIAGNOSTICS=true` adds a bounded
64-record first-invalid snapshot buffer, actual draw-call counting and successful
queue-submit-call ordinals. It requests normal exit at graphics time 25 seconds
and exports owned failure snapshots during telemetry shutdown, not during rendering.
Both host and game library must use the same flag because Context layout differs.
Normal builds have no diagnostic storage or recording work.

The isolated runtime is `planetforger/timing-run/`, with its own `build/game.dylib`;
no experimental wgpu library replacement occurred. Aesir launched this runtime and
recorded `artifacts/aesir-profile-1788701834-48088-314794623990750.jsonl`.
The process exited without the capture deadline firing, but Aesir rejected capture
health (`truncated`). No acceptance claim is made.

Post-exit trace: `artifacts/timestamp-game-diagnostic.tel.timing.json`.
Raw telemetry: `artifacts/timestamp-game-diagnostic.tel`.

First observed invalid frame:

| Field | Value |
|---|---|
| Context epoch / frame / generation / map request | 1 / 1 / 1 / 1 |
| Label / query pair / slot | window / 0,1 / 0 |
| Encoder / submit / resolve-submit ordinal | 1 / 1 / 1 |
| Encoded draw calls | **3** |
| Attachment load/store | Clear / Store |
| Begin / end ticks | 199207223920541 / 0 |

Frame 2, same slot, generation 2, also encoded three draws. Its begin is
199207248711083 and end is 199207224369708, earlier than this frame's begin.
This is not explained merely by asserting the window pass encoded no draws.
Draw encoding does not itself prove fragments executed, but it falsifies the
clear-only-encoding explanation for this captured category.

Raw health reports 218 invalid frames, zero map failures and zero no-free-slot
failures. Only 64 representative records were retained and 154 were explicitly
dropped by the diagnostic cap. Loading completions were not pumped continuously;
these are incomplete evidence, not all-label or gameplay coverage. Full metadata,
per-label retention, scene-copy bindings, attachment formats and callback-retirement
proof remain unfinished.

## Source-built pinned control: v4

The unpatched `wgpu-native` v29.0.1.1 control at revision
`6aed50955d934ac36049ba8d002034841633ae02` reproduces invalid game timestamps.
It was built with `WGPU_NATIVE_VERSION=v29.0.1.1 cargo build --release --locked`.
The earlier build without the version environment variable failed Odin's version
check; its manifest and two failed recordings remain separate evidence. No shared
backend library was replaced.

Capture: `artifacts/aesir-profile-1788705605-49211-318566150224791.jsonl`.
Sidecars: `artifacts/timestamp-control-v4.tel` and `.tel.timing.json`.
The target exited normally with code 0; Aesir retained 21 samples and rejected
health with exactly one read error. Invalid lines, resets, pending bytes and
exhausted terminal drain were zero. A missing startup sidecar is a hypothesis for
that read error, not an established cause.

Version 2 diagnostics retain 64 first failures and category representatives:

| Category | Invalid pairs |
|---|---:|
| window, three encoded draws, zero end | 3 |
| window, encoded draws, nonzero reversed end | 1226 |
| world.ocean, one encoded draw, zero end | 1 |

Total: 1230 invalid pairs, 1166 omitted from the first-failure array, no category
overflow. Pair counts must not be reported as frame counts. The first ocean
representative is epoch 1, frame/generation/map request 1225, slot 1, query 4–5,
encoder 1228, submit ordinal 1227, resolve-submit ordinal 1228, begin
203002231283541, end 0, callback Success, collection 1106. Its recorded attachment
is 2560×1440, color format enum 27, depth format enum 46, Load/Store, sample count
1. At capture time sample count came from the resolved texture, not necessarily
the render attachment; this metadata defect is now corrected but the old trace
must not be retroactively treated as corrected. Encoded draws do not prove
fragment execution. Ocean is a separate observed category, not an established
instance of the native resolve discrepancy.

`artifacts/timestamp-control-v4-identity-audit.json` hashes the surviving tagged
archive, host, actual `build/game.dylib`, compiler, capture driver and sidecars.
All 203 archived source files across wgpu-hal/core/types 29.0.3 match their crate
checksums, and package checksums match Cargo.lock. Vendored sources were inspected,
not configured as build replacements. This is a post-capture identity audit:
pre-build immutable source provenance and exhaustive loaded-input coverage remain
unproven. The window's 2560×1440 attachment under a 1280×720 logical-window recipe
is not fixed-world-target performance qualification.

## Discriminating native experiment: GPU resolve versus post-completion CPU resolve

Hypothesis: the earlier native fixture missed an additional failure because it
resolved counter values on the CPU after command completion, whereas wgpu encodes
`resolveCounters` on a GPU blit encoder. Compare the two paths in the same submission,
without changing the render workload. `--gpu-resolve` captures both arrays.

| Mode | Cases | GPU vs CPU render-counter mismatches | Drawn cases with reversed GPU begin/end |
|---|---:|---:|---:|
| Same command buffer, GPU resolve | 40 | 23 | 15 |
| Same command buffer, fragment fence plus 256-byte copy | 40 | 9 | 3 |
| Split command buffers, fence plus copy | 40 | 7 | 0 |

All seven split-case mismatches were clear-only. Some reused clear cases copied
**previous vertex counters too**, while post-completion CPU resolution had current
vertex counters. Fresh clear cases sometimes copied all zeros.

In drawn same-command cases, the GPU-resolved fragment values can match the prior
pass while CPU-resolved fragment values are current. This reproduces a stale
GPU-resolve result independently of Ingot callbacks and Aesir serialization.
It supports a counter resolve ordering/visibility defect distinct from the known
unwritten fragment stage issue. It does not yet distinguish missing synchronization
from driver counter-publication semantics or prove every game failure shares it.

Artifacts: `artifacts/timestamp-gpu-resolve{,-fenced,-split}.jsonl` and matching
manifests. Native source hash is recorded inside each capture and verified by the
evaluator. Each trial is correctness evidence only, not an overhead measurement.
The supplied wgpu artifact hash is identity metadata, not a linkage claim for Swift.

## Render-completion control: two independent failure mechanisms

The fixture now resolves only render counters 0–3, excluding the resolving blit's
own boundary counters. With identical source and workloads:

| Resolve topology | Cases | GPU/CPU mismatches | Drawn reversed pairs |
|---|---:|---:|---:|
| Same command | 40 | 40 | 32 |
| Separate command, no completion wait | 40 | 9 | 1 |
| Separate command, render completed before resolve | 40 | 0 | 0 |
| Repeat of completed-render control | 40 | 0 | 0 |
| Same command, fragment fence only, no copy | 40 | 28 | 21 |

All command statuses were completed without errors. In both completed-render
runs, all eight clear-only cases still had reversed begin/end pairs, even though
GPU and CPU resolution agreed exactly. Reused clear-only fragment counters
retained the preceding draw's values while vertex counters advanced.

This separates two mechanisms: premature GPU resolution can return stale render
samples; independently, absent fragment execution leaves fragment-end unsuitable
as a current pass-end measurement. A separate command submission alone does not
establish the required visibility. Waiting for render completion removes the
observed resolve disagreement in 80 cases, but is a diagnostic control only.
Whether the missing dependency reflects invalid Metal usage or a backend/driver
contract defect remains unresolved. Exact game-draw replay is still required to
attribute window and ocean failures individually.

Source SHA: `5c0a669410c8770752ca958c3baec32a1ef1e5ff3f4705b1d9e4f78181078467`.
Artifacts and hashes: `artifacts/timestamp-render-completion-comparison.json`,
with four referenced JSONL runs. No CPU wait was added to production rendering.

## Consequences for repair selection

Earlier ordered fenced-blit timestamps were insufficient: GPU-resolved timestamps
still failed in the same-command fenced trial. Do not integrate that candidate as
a production repair. No new fallback, dummy draw, timestamp clamp or vertex-end
substitution is authorized by this finding.

The completed-render control above has now passed its diagnostic comparison, not
its production gate. The fence-only control still disagrees in 28/40 cases, with
21 drawn reversed intervals, seven clear mismatches, one reversed GPU clear pair
and eight reversed CPU clear pairs. All render and boundary commands completed
without errors. No copy or other dummy workload was encoded. A fragment fence
alone therefore does not establish counter freshness in this fixture.

The measured interval compares start-vertex index 0 with end-fragment index 3,
not vertex indices 0/1. In fence-only capture line 22, GPU samples are
`[216304900438791,216304900450041,0,0]`; CPU fragment end is `216304900464541`.
Line 3 instead returns a completely stale but ordered prior-draw array. Neither
ordered vertex counters nor an ordered full array establishes current-pass freshness.

The exact source is preserved as `artifacts/timestamp-render-range-source.swift`,
with SHA `5c0a669410c8770752ca958c3baec32a1ef1e5ff3f4705b1d9e4f78181078467`.
The fence-only capture is `artifacts/timestamp-render-range-fence-only-control.jsonl`,
SHA `f18fd9663d800d60d28bed346717e8276139019c8c7c95e20778f77ac269a83c`.
All five render-control captures have adjacent `-postrun-manifest.json` files.
These record automated evaluator results, source/capture/evaluator hashes, device
metadata and uniform topology flags. They are post-run verification, not pre-build
provenance: historical Swift compiler and binary identities were not recorded.
Swift does not link wgpu. Existing archives and comparison manifests are preserved.

Apple's reviewed documentation distinguishes CPU resolution after pass completion
from GPU blit resolution, without specifying a counter-publication fence requirement:
- https://developer.apple.com/documentation/metal/converting-a-gpus-counter-data-into-a-readable-format
- https://developer.apple.com/documentation/metal/mtlblitcommandencoder/resolvecounters(_:range:destinationbuffer:destinationoffset:)
- https://developer.apple.com/documentation/metal/mtlcountersamplebuffer/resolvecounterrange(_:)
- https://developer.apple.com/documentation/metal/mtlrendercommandencoder/samplecounters(samplebuffer:sampleindex:barrier:)

Encoder-local sampling barriers do not isolate other passes. No explicit clear-only
fragment-slot guarantee was found. These documentation gaps do not establish valid
usage or a driver bug. Pinned Metal `command.rs:829–850` resolves on a blit encoder
without a counter-specific fence; `991–1003` maps vertex start and fragment end.
Exact game replay and supported interval semantics remain required before selecting
any repair. If unavailable, expose unreliable timing rather than changing semantics.

## Callback dispatch audit: pinned sources, not a retirement proof

Local `artifacts/wgpu-native-control/src/lib.rs:1020–1075` captures raw userdata
in the map callback closure, ignores callback scheduling mode, and returns a null
future. It does not acquire ownership of the pointed-to application storage.
In `vendor/wgpu-core/src/resource.rs:789–833`, mapping removes the pending
operation from buffer state and returns the operation for later dispatch.
`vendor/wgpu-core/src/device/mod.rs:177–199` invokes extracted callbacks outside
resource locks, mapping callbacks before submitted-work callbacks.

`resource.rs:837–844` synchronously invokes the cancellation callback returned by
`unmap_inner` when one is still pending. This is **not a join for an operation
already extracted for dispatch**: buffer state no longer contains that closure.
Neither an unmap return nor a generation comparison alone proves application
userdata or callback code can be freed/unloaded. The partial subagent wording
that unmap "joins" callbacks applies only to inline cancellation, not concurrent
or extracted callbacks. Lifecycle implementation must preserve that distinction.

Current diagnostic regressions cover all reversed pairs, owned snapshot copies,
multisampled render attachment counts, depth/clear metadata, and abandoned encoder
handle reuse. Generic command and screenshot QueueSubmit calls now participate in
the ordinal stream. These are metadata repairs, not GPU freshness or callback
lifetime repairs. Previously verified: 346 gfx tests enabled and disabled;
five Python evaluator tests pass. The full repository check currently stops at provenance approval for
six already-tracked isolated build artifacts. The root style scan also traverses
archived source trees; those archives must not be reformatted as production code.

## v5 game diagnostic attempt and external capture blocker

Schema 4 adds bounded first-four draw descriptors (counts, instances, shader ID,
pipeline kind/style and scissor), explicit draw overflow, and owned prior mapped
query-pair values with epoch/frame/generation. Prior values are retained for all
successful mappings, including ordered frames, and identify the same physical
slot/query pair; they are not independent CPU-resolved native counter evidence.
Unknown draw paths remain explicitly unknown. Window batch and GPU3D indexed
paths are wired. Exact geometry, uniforms, texture contents and pipeline source
identity are still required for exact replay; these descriptors alone are not it.

Isolated host/client built in `artifacts/timing-game-v5` using the isolated Odin
compiler and pinned source-built backend archive, without shared replacements.
`prebuild-inputs.json` covers copied game/shared/host and gfx sources only; other
Ingot packages and linked assets remain live. `identity-audit.json` records
post-capture binary/sidecar identities, not exhaustive pre-build provenance.

The initial relative command failed to launch. An absolute command launched but
lacked `AESIR_TELEMETRY`; its recording retains 22 read errors. The explicit-env
attempt produced `artifacts/aesir-profile-1788722622-85252-335582698516791.jsonl`
and `artifacts/timestamp-game-v5-evidence.tel{,.timing.json}`. Target exit was 0;
Aesir retained 21 samples, rejected health with one read error, and raw telemetry
reported 1280 delivery drops. Only frame 1 encoded rendering: the window failure
has begin `218858941214750`, end 0, three indexed draws of 1080/66/318 indices,
one instance each, built-in Solid/Alpha pipeline, full 2560×1440 scissor. No ocean
or prior-slot failure was observed. Later retained frames have no encoding or
submission, so a lower failure count is not a repair.

A direct `CGSessionCopyCurrentDictionary` check reports
`CGSSessionScreenIsLocked = 1`. Pinned Metal `surface.rs:123–151` explicitly returns
Occluded when the window is not visible. The locked desktop prevents the required
sustained visible-window capture; no unlocking, visibility bypass or rendering
workaround was attempted. Unlocking the local desktop is required before retrying
this game gate. The diagnostic debugger attempt was stopped and is not Aesir
qualification evidence. Step 2 stays in progress; step 3 has not begun.

Latest verification: 348 gfx tests passed enabled and disabled, the assembled
ForgeCore identity-decode test passed, and five Python evaluator tests passed.
Direct ForgeCore-only compilation is invalid because its union package requires
PlanetForger types/assets; the isolated assembled test supplies them. Production
callback ownership and telemetry transport remain unrepaired.

## September 7 continuation

Desktop recheck returned an active console session and one screen, without the
screen-locked flag. This removes the previously observed lock evidence, not the
need to verify sustained visible rendering in the next Aesir run.

Draw diagnostics now distinguish built-in batch and GPU-3D enum domains. A failed
custom-shader fallback records the actual built-in shader identity (zero), and
window attachment diagnostics retain the configured clear RGBA instead of zeros.
The four-descriptor limit is named; overflow remains explicit.

Diagnostic-profile `game_prepare` now drains into existing owned telemetry arrays
on every host frame, including loading, without invoking serialization or writes.
This only retains the first bounded packet: 16 GPU records and 32 delivery records.
Once full, renderer rings can still overflow until gameplay/shutdown pumps them.
This is not a continuous-delivery repair or a completed loading trace gate.

The isolated `artifacts/timing-export-check-v8` union passed three focused tests:
no-I/O collection with full buffers, diagnostic JSON roundtrip including prior
samples and integers above 2^53, and invalid-timestamp identity decoding.
The preceding v7 union passed the two wire tests with diagnostics disabled.
Web checking with real shared types encountered existing unsupported `core:os`
imports and a 32-bit `max(u32)`-to-int conversion in `flora_ecology.odin`; no web
compatibility claim is made. No game recapture or timing repair is claimed.

Window draw retention now owns at most 16 complete batches, each bounded to 2048
vertices and 4096 indices. These budgets cover the observed small first-window
batches, not arbitrary game geometry. Geometry IDs are one-based; zero denotes
missing inputs. Only retained, unsubmitted draw bindings consume this budget;
count mismatches are reported as dropped geometry, never partial input copies.
The CPU projection shadow records logical dimensions at uniform upload. Alternate
uniform bindings remain explicitly unknown. Ownership, overflow, reset and
failure-linkage tests pass; gfx now has 353 passing tests with diagnostics enabled.

The v10 nontrivial projection roundtrip exposed lossy default JSON float formatting:
1/720 changed on decode. Draws now also carry exact `projection_bits` as four u32
IEEE-754 words; replay must use those words, not the human-readable float array.
The v11 union passed all three focused telemetry tests with bit-exact projection
reconstruction and prior ticks above 2^53. Geometry float JSON still needs an exact
wire representation; current schema-5 export is not reconstructable evidence.
Texture/atlas versions, ocean inputs, immutable build provenance and sustained
loading transport remain missing. No new Aesir capture or production repair occurred.

Schema 6 replaces geometry float arrays with active-length vertex/index slices.
Each vertex exports position/color/UV as explicitly sized IEEE-754 u32 words and
mode as u32, avoiding dependence on formatter precision or host struct padding.
The shutdown-only conversion copies into temporary owned wire arrays; source reset
cannot alter the export. Tests cover signed zero, subnormal, rounding-sensitive,
maximum finite, NaN payload and infinity bit patterns, plus exact drop counts above
2^53. These patterns verify retention, not permission to submit non-finite geometry.
The v15 union passed four focused tests enabled and disabled; formatted v16 passed
four enabled. New assemblies use the v11 gameplay baseline plus current telemetry
sources because fresh v12 found concurrent `marine_test.odin` using obsolete
Planet_Coord x/y fields. No concurrent simulation code or pin was modified.
This is test-only assembly evidence, not frozen game capture provenance.
Texture/atlas inputs and ocean data remain unretained; step 2 is still incomplete.

Schema 7 adds bounded atlas upload evidence: the first 256 glyph uploads and at
most 1 MiB of tightly packed R8 pixels, copied before rasterizer scratch is freed.
This budget targets initial loading text, not all fonts over the context lifetime.
Every initialized atlas has a monotonic ID and a zero-filled 2048-square R8 base.
Each matched draw records atlas ID, global upload prefix, filter and explicit
known status. Reconstruct by applying only matching-ID uploads before that prefix
in order. Samplers use clamp-to-edge, nearest mip filtering and the recorded
point/linear min/mag filter. Any prior dropped upload conservatively makes later
atlas draws unknown. Non-atlas textures remain unknown. Shutdown exports active
upload/pixel slices; no GPU readback, CPU wait or frame I/O was added.
Two new tests cover padded-row copying, ownership, bounds, invalid regions,
capacity rejection, draw-prefix lookup and copy-out survival. All 355 gfx tests
passed enabled and disabled; the v17 stable-baseline union passed two focused
wire tests. Actual glyph-hook GPU execution and schema-7 atlas JSON roundtrip are
not yet regression-covered. No new game capture, ocean retention or repair claim.

Atlas continuation: the v18 stable-baseline union passed five focused tests,
including schema-7 byte/upload/draw roundtrip with values 128/255 and drop counts
above 2^53. `replay_inputs.py` reconstructs the zero-based R8 atlas using only the
matching atlas ID and retained upload prefix, rejecting unknown evidence and
invalid ranges. Four Python regressions verify overlapping writes, other-atlas
isolation, excluded later writes, invalid prefixes/ranges and zero initialization;
the combined Python suite now passes nine tests.

The draw prefix is now sealed at encoder submission, not merely draw encoding:
queue texture writes issued after encoding but before submission precede that
command buffer. A drop before submission invalidates its atlas completeness;
later drops do not rewrite previously submitted evidence. The submit regression
passes; gfx now passes 356 tests in both diagnostic modes. These are CPU evidence
and wire tests, not native replay or a newly captured game failure.

Window geometry reconstruction now converts retained u32 words into explicit
little-endian 36-byte vertices, u32 indices and 16-byte projection uniforms without
round-tripping through Python floats. It rejects unknown/non-batch draw paths,
missing identities, retention-limit violations, mismatched counts, unsupported
instance counts and indices outside the retained vertices. Three new regressions
cover exact signed-zero/NaN-payload bytes and rejection cases; all 12 Python tests
pass. This reconstructs input buffers only, not shaders, pipelines, attachment
contents or GPU execution, and does not satisfy the game-replay gate.

## September 7 selected-window contract implementation

Schema 8 now exports the compiled built-in WGSL text and exact attachment clear
words (f64 color/u64 words and f32 depth/u32 word), alongside the neutral texture
identity. The telemetry regression reconstructs clear values from the words before
comparison, avoiding JSON float rounding. A missing uniform bind is now explicitly
unknown even if a cached projection exists.

All four diagnostic submit hooks now seal records immediately before QueueSubmit,
not after it returns. This closes the evidence-ordering gap for inline callbacks;
it does not repair callback userdata lifetime or prove GPU command success.
The current reset audit found production timing-state zeroing at shutdown, after
resource destruction in normal context close. No live diagnostic reset API was
found; adding one would require atlas ID epoching rather than reusing IDs.

The selected v5 invalid window pass remains unreconstructable: all three draws
lack retained geometry/texture inputs, exact clears and compiled shader text.
`window_readiness.py` reports these missing inputs with an independent report
version. It also explicitly rejects full readiness pending an immutable actual-build
pipeline manifest and complete producer/resolve command topology; it cannot certify
replay even when the retained buffer subset is complete. The report is not a GPU
replay. No new game capture was made during this implementation.

Schema 9 closes the pipeline-descriptor input: `_make_pipe` now records the exact
descriptor it hands to the device (vertex layout, primitive, multisample, blend,
write mask, target format) into `Renderer.diagnostic_pipelines`, keyed by (kind,
blend slot), keeping only the swapchain-format set. ForgeCore exports the eight
entries as pinned integers under `batch_pipelines`. `replay_inputs.batch_pipeline`
verifies the draw's selected descriptor against the fixed contract and the record's
attachment format; readiness now reports only `source_manifest` and
`queue_topology` unconditionally. The v5 capture additionally fails this check.
The `timing-window-contract-v2` snapshot records the post-change sources; its WGSL
hash equals v1.

Verification: 359 gfx tests enabled/disabled after pipeline retention; 26 Python
tests; v23 six focused telemetry tests enabled and disabled (adds
`telemetry_diagnostic_pipeline_roundtrips_pinned_values`). v22/v23 remain
preserved-baseline union evidence, not current gameplay build verification. Gfx assertion checking passes after adding
actual query/slot bounds at the render-pass hook. A direct gfx style scan reports
pre-existing long JavaScript strings in platform_web.odin. Concurrent repository
hygiene-script changes were left untouched.

## September 7 frozen loading-inclusive captures (v6, v7, v8)

Desktop visibility was rechecked (`CGSSessionScreenIsLocked` absent, on console, one
screen) before each launch. `freeze_build_inputs.py` copied the live forgecore +
planetforger union, demo assets and every Ingot collection package into
`artifacts/timing-game-v{6,7,8}/` and hashed 849 files each before building with the
isolated compiler (`5baf1357…`) and the pinned source-built wgpu archive
(`d923b033…`). Repository heads and dirty flags are in each `prebuild-inputs.json`;
planetforger was dirty with concurrent ocean/surf work, which built cleanly and was
not modified. Each tree was built with the same diagnostics ABI for host and library
(`build-commands.log`) and launched through the rebuilt Aesir capture driver
(`timestamp-aesir-capture-v6`, `0c0dd44e…`) with absolute paths and explicit
`AESIR_TELEMETRY`.

v6 (schema 9): 64 window failures over frames 1–68, 492 dropped; 62 reversed ends
and 2 zero ends. Textures were unreconstructable because the 256-upload atlas budget
saturated before frame 1 (1482 dropped). Every reversed end equals the begin tick of
the frame two frames earlier plus 109–212 µs while begin ticks stay monotonic—the
stale end-of-pass sample signature. Attribution is deferred to the replay step.

v7 (schema 10): with the budget raised to 2048 and `atlas_dropped_bytes` exported,
all 1738 uploads (420,681 bytes) were retained with zero drops, and frames 1–5 held
every draw input. Topology fields and the build-manifest check did not exist yet.

v8 (schema 11): `span_count`/`encoder_spans` are exported. With
`--build-dir artifacts/timing-game-v8`, `window_readiness.py` certifies frames 1–4
(`readiness-all.json`): frame 1 zero end with prior sample explicitly absent, frame 2
reversed end with frame 1's sample present, frames 3–4 zero ends. All certified
frames are single-span, same-encoder submissions. 64 records cover frames 1–67 with
1252 later failures dropped and 4528 geometry drops accounted; only the `window`
category appeared—no ocean pass was recorded, so ocean remains uncovered.

Aesir independently rejected every capture: the recording is flagged truncated,
`telemetry_health.read_errors` is 1, and only 8–12 raw telemetry lines were written
over 25 s. Raw `gfd` entries additionally mark frames such as v6 frame 3 as valid
with an absurd 16,275,202 ms duration, promoting an unknown sample. These are
transport and reliability defects for the later step, not timing repairs. A
concurrent PlanetForger profile hook also writes a `.terrain-<sha>.wgsl` sidecar
next to the telemetry path; it is not part of this evidence.

Verification: 360 gfx tests enabled and disabled; 29 Python tests; v24 and v25 six
focused telemetry tests enabled and disabled; assertion and style checks clean.
After step 3: 367 gfx tests enabled and disabled; v26 seven focused telemetry
tests enabled and disabled; ForgeCore host tests; 62 Aesir memwatch tests.

## September 7 callback ownership and teardown repair (step 3)

Pinned dispatch facts re-verified in `artifacts/wgpu-native-control` before any
change. Map callbacks run on the calling thread from four entry points, never
from a backend thread: `wgpuBufferMapAsync` (inline on validation failure,
`vendor/wgpu-core/src/device/global.rs:2066–2092`), `wgpuQueueSubmit` (the
submit path runs `maintain(Poll)` and fires the collected closures before it
returns, `vendor/wgpu-core/src/device/queue.rs:1468–1501`), `wgpuDevicePoll` /
`wgpuInstanceProcessEvents` (`global.rs:1860–1873`), and `wgpuBufferUnmap` /
`wgpuBufferDestroy`, which answer a waiting map with an inline `Aborted`
(`resource.rs:837–846`, `global.rs:240–258`). A pending mapping keeps the
buffer alive (`BufferPendingMapping._parent_buffer`), so release without unmap
is not a cancel either. The Metal fence completion block only touches an
`Arc` atomic (`vendor/wgpu-hal/src/metal/mod.rs:546–564`), but its code lives
in whichever binary called `QueueSubmit`; the ForgeCore game library links its
own renderer and wgpu copy (`nm build/game.dylib` in v8 lists `_wgpuQueueSubmit`,
`_gfx::_screenshot_map_done` and `_gfx::_submission_done`), so a hot unload
while its work is outstanding can strand code the backend still calls.

Defects found in our ownership, all independent of the counter defect:

- Timing: `Gpu_Timing_Map_Request` lived inside the mutable slot and the
  callback wrote slot fields directly; `_gpu_timing_shutdown` destroyed the
  readback buffers after a bounded poll regardless of outcome, relying on the
  inline abort to land before `slot = {}`.
- Screenshot: `Screenshot_Map` was a stack local of `_screenshot_map`; on the
  timeout path the caller's deferred `BufferDestroy` delivered the inline
  `Aborted` callback into a popped frame.
- Submissions: `_close_window_context` turned an undrained tracker into
  `ensure` (a crash), not a refusal, and destroyed renderer resources before
  attempting to drain.
- Hot unload: the ForgeCore host reloaded the game library without proving the
  backend held no registration or completion block pointing into it.

Repair (`gfx/gpu_timing.odin`, `gfx/screenshot.odin`, `gfx/submission.odin`,
`gfx/context.odin`, `ui_gfx/app.odin`, `fit/app.odin`, ForgeCore
`host/main.odin`):

- `Gpu_Timing_State.requests[GPU_TIMING_FRAME_SLOTS]` holds one immutable
  registration record per slot. The submitter writes identity and arms it with
  a release store before `BufferMapAsync`; the callback is the only writer of
  `ticks/status/mapped` and publishes with a release store on `done`; the
  collector acquires `done`, asserts the record still matches its slot, copies
  into the slot, unmaps only after a `Success`, and retires (`record = {}`).
  Slots carry an explicit `Gpu_Timing_Phase`
  (`Free -> Recording -> Resolved -> Map_Pending -> Result_Ready | Map_Failed
  -> Free`, plus `Quarantined`). A callback for an unarmed or already-done
  record is counted in `health.stray_callbacks` and never published.
- `_gpu_timing_retire` sets `closing` (new frames are refused and counted in
  `health.closed_rejections`), makes bounded progress, then attempts cancel by
  `BufferUnmap` and re-collects; unmap is treated as a request, not a join.
  Slots still pending are `Quarantined`, `_gpu_timing_release` asserts none
  remain, and `_gpu_timing_shutdown` returns false while retaining storage and
  buffers. A later terminal callback retires a quarantined slot normally.
- `Screenshot_Map` moved into `Context.screenshot` with the same arm/done/stray
  protocol; a timed-out capture leaves the record owning its staging buffer,
  later captures first try one non-blocking retire and refuse otherwise.
- `_submission_done` counts callbacks naming no live ticket; `_submission_quiesce`
  is the bounded, non-closing drain shared by shutdown.
- `_close_window_context` retires submissions, the screenshot map and timing
  before destroying anything and returns `false` on refusal, leaving the
  context in `.Closing` with every object intact and retry-safe.
  `context_close`, `CloseWindow`, `ui_gfx.app_destroy` and `fit.Destroy` now
  return that bool; partial-init cleanups route through
  `_abandon_window_context`, which asserts an uninitialised context cannot
  refuse. `context_quiesce_gpu` is the non-closing variant for hosts.
- ForgeCore host: `reload_game` defers a reload until `context_quiesce_gpu`
  succeeds, `restart_game` `ensure`s it after the library's shutdown, and
  process exit keeps the library loaded when `CloseWindow` refuses.
  Telemetry `gh` gained `sc` (stray callbacks) and `cr` (closed rejections);
  Aesir's `GPU_Timing_Health` decodes both.

Tests (`gfx/gpu_timing_test.odin`, `gfx/callback_ownership_test.odin`) deliver
through the registered userdata addresses: stray before arm, terminal `Error`,
duplicate after terminal (fault injection beyond the one-callback contract),
late after retire, out-of-order failures across all eight slots, inline
delivery immediately after arming, permanent stall with a nil device
(quarantine, refused release, refused `context_close`, refused
`context_quiesce_gpu`) followed by a late `Aborted` that retires it, screenshot
strand/retire, and submission stray/epoch accounting.

This step proves storage and code lifetime for our registrations. It changes
nothing about counter publication; the captures below are the before/after
signature comparison that the gate demands, not a repair claim.

### v9: phase leak caught by the frozen capture, not by unit tests

The first frozen build with the phase machine (`artifacts/timing-game-v9`)
reported `gh.s` (`no_free_slot`) = 1175 with a single invalid timestamp: every
slot was stranded in `Recording`. A frame that never reaches submit (surface
unavailable or acquire failure takes `context_end_drawing`'s no-frame branch)
used to leave a slot with `in_flight = false`, which the old selector treated
as reusable; the explicit phase made that leak visible. A 90-frame probe
window reproduced it in eight frames. Repair: `_gpu_timing_frame_begin`
abandons a leftover active slot and the no-frame branch of
`context_end_drawing` abandons explicitly; `_gpu_timing_frame_abandon` asserts
it never abandons an armed slot. Regression:
`gpu_timing_unsubmitted_frame_frees_its_slot`. The v9 tree, binaries and
capture are retained as the failing evidence; v10 is the same source plus that
repair.

The same probe (a 640x360 window drawing one rectangle at 60 Hz) reported
invalid timestamp pairs in 2, 0 and 6 of successive 15-frame windows, with the
collector otherwise healthy. The counter defect therefore reproduces without
the game, which is the minimal replay input step 4 needs.

### v10: signature after the repair

`artifacts/timing-game-v10` (frozen tree, `identity-audit.json`,
`signature-comparison.json`, `readiness-all.json`) is the post-repair capture.
Collector health is clean for the first time: `no_free_slot` 0, `map_failure`
0, `overflow` 0, `stray_callbacks` 0, `closed_rejections` 0, and the host's
`CloseWindow` returned true (the process exited normally). The counter
signature is unchanged from v8: 64 retained failures, 3 zero ends and 61
reversed ends across slots 0–2, `window` only, single span on a single
encoder, invalid pairs over 872 collected frames (v8: 1316 over a longer
telemetry window). `window_readiness.py --build-dir artifacts/timing-game-v10`
certifies frames 1, 11, 12, 13 and 14; frame 11 is a reversed end whose end
tick (`18796717235625`) is frame 1's begin tick + 209 us, the same stale-end
shape seen in v6 and v8. Aesir still rejects the recording (truncated,
`read_errors` 1, 8 telemetry lines), unchanged and deferred to step 5.

Step 3 gate outcome: storage and code lifetime are proved by construction and
by the tests above; teardown refusal is observable (`context_close` false,
`CloseWindow` false, host keeps the library); the captured signature is
identical before and after, so the ownership repair is explicitly not a
counter repair.

## September 7 attribution: exact replay of the captured window pass (step 4)

Inputs: `artifacts/timing-replay-v10-f1/` is the bundle
`export_replay_bundle.py` wrote from v10 failure 1 (frame 11, the reversed end
with frame 1 as its prior sample, certified by `window_readiness.py
--build-dir artifacts/timing-game-v10`): captured WGSL (sha `c3a29d73…`),
three draws (1080, 66 and 300 indices; neutral texture, atlas 1, atlas 2 at
linear filter), projection words, retained BGRA8Unorm pipeline descriptors,
exact clear words, full-attachment scissors and the single-span topology.
`attribution-manifest.json` records every input, source, binary and run hash.

Three programs consume that bundle unchanged, one hypothesis each:

1. `replay/main.odin`, built with the pinned control compiler against the
   pinned wgpu archive: opens the window through ingot:gfx (2560x1440
   BGRA8Unorm swapchain, asserted), re-encodes the pass itself with
   `timestampWrites {0, 1}`, resolves and copies in the same encoder, one
   submit, one map per iteration, eight readback slots, no CPU wait.
2. `native_replay.swift --gpu-resolve`: the same window, drawable, draws and
   the exact wgpu-hal Metal topology (`sampleBufferAttachments[0]
   startOfVertex=0, endOfFragment=1`, blit `resolveCounters(0..<2)` and copy
   in the same command buffer, present on a separate command buffer).
3. `native_replay.swift --completed-resolve`: identical render encoding with
   no resolve in the render command buffer; the resolve and copy are encoded
   in a second command buffer only after the render command buffer completed.
   Diagnostic control only.

| Run | Samples | Ordered | Zero end | Reversed | Stale by one pass | Median duration |
|---|---:|---:|---:|---:|---:|---:|
| WebGPU pinned replay, run 1 | 300 | 13 | 1 | 286 | 280 | 197.1 us |
| WebGPU pinned replay, run 2 | 300 | 2 | 1 | 297 | 292 | 201.8 us |
| Native GPU resolve, run 1 | 300 | 1 | 1 | 298 | 297 | 198.4 us |
| Native GPU resolve, run 2 | 300 | 11 | 1 | 288 | 287 | 200.4 us |
| Native render-completed resolve | 300 | 300 | 0 | 0 | 0 | 196.9 us |

All 1500 commands completed without error-scope or command-buffer errors.
"Stale by one pass" means the reversed end tick of iteration N equals the
begin tick of iteration N-1 plus that pass's own duration within 50 us: the
resolve returned the previous pass's end-of-fragment sample from the same
sample index, while start-of-vertex was current. The first use returns 0
because the index had never been written. The few ordered samples in the
failing modes carry the current duration, so publication is racy rather than
always late. Presentation ran at the display's 120 Hz (8.5 ms begin period)
in every run. The game's captured signature (end tick equal to the begin of
the slot's previous frame plus 110–212 us; zero on first use of a slot) is the
same mechanism with per-slot query sets.

Decision-table outcome: the application encoding is valid per Apple's
documentation, which requires post-completion access only for CPU
`resolveCounterRange` and places no ordering requirement on a blit
`resolveCounters` (pages listed above). The pinned backend's Metal topology
(same-command-buffer GPU resolve) is the trigger and the native control shows
the trigger is the device's stage-boundary counter publication, not wgpu
code. This is an evidenced native-limitation/unresolved-publication result:
GPU pass durations resolved in the same command buffer are unsupported on
Apple M2 Max / macOS 15.6.1. gfx-rs/wgpu#9414 is a different symptom: all-zero
legacy counter-sample-buffer results on macOS 26 / Metal 4, not this
stale-by-one-pass result on macOS 15. Its community thread contains an unmerged
completion-handler-deferred resolve proposal relevant to a candidate topology;
nothing merged upstream. The render-completed control is not a production
repair: it waits on the CPU and serialises submissions. No timestamp clamp,
vertex-end substitution or dummy work is authorised; production must publish
this timing scope as unreliable
(step 5 reliability fields) until a nonblocking candidate built from identical
pinned sources passes `evaluate_replay.py` (`candidate_passes`: every per-index
GPU value equals the post-completion CPU value, no stale-by-k match, at most one
first-use zero, drained, no command failures).

Interval definition for any future candidate: the measured interval is
start-of-vertex to end-of-fragment of the timed render encoder; clear-only
passes have no fragment stage and are unsupported for this interval (native
matrix above); overlap with the following present command buffer is not part
of the interval. Ocean has its own category and no capture yet; it cannot
inherit this attribution.

## September 7 transport and reliability propagation (step 5)

Before: ForgeCore collected GPU and delivery records only under the
diagnostics build, wrote every line synchronously from the frame thread, and
only `telemetry_publish` (gameplay) or `telemetry_shutdown` (a bounded
eight-packet burst) ever drained them. v10 showed the consequence: eight raw
lines in 25 s, `fdd` 1173 deliveries dropped during loading, and Aesir marked
the recording truncated because its first ticks opened a sidecar that did not
exist yet (`read_errors` 3) and every absence counted as a read error.

ForgeCore `client/telemetry.odin` now implements the single-consumer contract:

- Eight owned packets (`TELEMETRY_PACKETS`), each one raw line (16 GPU frames,
  32 deliveries, health) or one summary snapshot, moving
  `Free -> Producer -> Queued -> Writer -> Free`. The frame thread drains
  ingot's rings every frame (`game_prepare`, loading included) into the
  producer packet and seals it when full or at the 1 s cadence; when the
  writer holds every packet the drained records are counted
  (`pd` packet drops, `pfd` frames, `pdd` deliveries) rather than left to
  overflow inside ingot.
- A writer thread is the only encoder and the only writer. Lines are encoded
  into a 64 KiB buffer (aesir's line limit; an overflow is counted in `eo` and
  withheld, never torn) and written with a byte offset that advances on
  every short write (`pw` partial, `zp` zero-progress, bounded by
  `TELEMETRY_WRITE_ATTEMPTS_MAX` before `wf`). `qh` is the queue high water,
  `lw` lines written.
- The summary is a value snapshot (`Telemetry_Summary`) taken on the frame
  thread and encoded by the writer; it never drains the rings.
- Shutdown: final collect, seal, terminal packet, bounded join
  (`TELEMETRY_SHUTDOWN_DEADLINE`). A stalled writer makes
  `telemetry_shutdown` return false and `telemetry_release_pending` true;
  `game_shutdown` then keeps `g` allocated and returns false, and the host
  (`Game_Shutdown_Proc -> bool`) keeps the library loaded instead of
  unloading the thread's code. Regressions: sustained production past the
  ring, backpressure accounting, short and zero-progress writes, encode
  overflow, stalled-writer refusal and later release, exact >2^53 identities.
- Every line carries `"rl":{"v":1,"s":"gpu_pass","g":...,"r":...}`. Darwin
  builds publish `unreliable` with reason `metal_same_command_buffer_resolve`
  (step 4); other platforms `unknown` with `no_attribution_evidence`. Nothing
  in the target can set `reliable`; only a candidate that passes
  `evaluate_replay.py` may change that.

Aesir `memwatch`:

- The tail distinguishes bounded startup absence (`startup_absent`, up to
  `MAX_TELEMETRY_STARTUP_ABSENT` ticks before the first byte; not a loss)
  from read errors, parse errors (`parse_errors`) from oversized lines
  (`invalid_lines`), file reset (`resets`) and an unfinished final line
  (`unfinished_tail`, pending bytes after the final drain). One definition,
  `telemetry_health_incomplete`, drives the recording's coverage verdict,
  the bottleneck coverage and the truncation flag.
- `parse_telemetry` decodes `rl` into `gpu_reliability`; unless the scope is
  `gpu_pass` and the word is `reliable`, `gv` is cleared, raw `gfd` frames
  are marked invalid and `gg` groups are dropped. Legacy lines without `rl`
  are `Unknown` and rejected the same way. Deliveries (CPU, presentation)
  stay independently valid. The GPU badge shows the reason code.

## September 7 Aesir qualification and causal ledger (step 6)

v11 (`artifacts/timing-game-v11/`) is a fresh frozen build of the step 3–5
sources (`prebuild-inputs.json`, `identity-audit.json` record heads, dirty flags
and the `timestamp-aesir-capture-v7` driver hash) built with the isolated
compiler and pinned wgpu archive, captured three times through Aesir with the
same binaries (`capture-command.log`, `control-run2/`, `control-run3/`).
`tests/metal_timestamps/qualify/main.odin` loads each recording with Aesir's own
`memwatch` decoder and writes `qualification.json`; the three reports are
collected in `control-three-runs.json`.

Capture-health gates, from the recordings rather than the producer:

- Complete, not truncated: `telemetry_health` is all zero except
  `startup_absent` 1 (one tick before the sidecar existed, bounded and not a
  loss); `unfinished_tail`, `drain_exhausted`, `discarding` false. Producer
  stats on every line: `wf`, `eo`, `pw`, `zp`, `pd`, `pfd`, `pdd` all 0,
  `qh` 2 of 8 packets, 49/49/47 raw lines plus summaries over 25 s (v10 had 8).
- Loading through gameplay in one epoch: frames 1–1505, 1–1547 and 1–1471 with
  a delivery record for every frame (`delivery_frames` equals the frame span,
  `sequence_gaps` 0). Deliveries without a presented timestamp are counted as
  `invalid_delivery_frames` (4, 13 and 3): the loading frames before the first
  present (first presented frame 4, 12 and 3; run 2 frames 2–10 also carry
  `mg`/`mp`, missing GPU and present callbacks, from the loading window) plus
  a short run of frames without a present after loading (1414; 30–31; 1443),
  which is also the single `delivery_gaps` in each cadence analysis. The gameplay
  summaries carry `world.opaque`/`world.ocean` groups, and run 1 raw frames
  1422 and 1432 record window, `world.opaque` and `world.ocean` passes, so the
  capture crosses from loading into world rendering.
- Exact identity joins: `conflicting_identities`, `sequence_gaps`,
  `sequence_duplicates` 0; every presented delivery joins by exact
  (epoch, frame) identity. `exact_join.healthy` is false because the raw GPU
  frames are rejected (`invalid_raw_gpu_frames` 231, `invalid_timestamps`
  1274, `joined_frames` 0) and because of the non-presented deliveries above:
  every record carries `rl.g = unreliable`,
  `rl.r = metal_same_command_buffer_resolve`, Aesir stores `grl` 2 with `gv`
  false on all 51 records and `gpu_attributed` is 0. That is the required
  behaviour for unsupported timing: a visible reason code and no fabricated
  durations.
- Callback and worker retirement: `gh.sc` (stray callbacks) and `gh.cr`
  (closed rejections) are 0 on every line; the host exited 0 in all three
  runs, which requires `telemetry_shutdown`, `game_shutdown`, `context_close`
  and `CloseWindow` to all return true (a refusal keeps the library loaded and
  is logged; none of the `capture.log` files contain one).

### Causal ledger

| Symptom | Owning layer | Evidence | Fix or limitation | Regression | Artifact |
|---|---|---|---|---|---|
| Reversed or zero end-of-pass GPU timestamps (window pass; 61 reversed + 3 zero in v8/v10) | Metal stage-boundary counter publication, exposed by ingot `gfx` through wgpu-hal's same-command-buffer `resolveCounters` | Exact v10 replay plus M0–M7: current vertex samples but previous fragment samples; publication median 29.1 us after the fragment-end timestamp, one 1.72 ms in-buffer compute gap removes all reversals, a colour-attachment dependency does not, and Instruments shows 690/690 same-command resolve blits start after fragment execution | Mechanism H-A: late asynchronous fragment-stage counter publication races the following resolve. This is pure Metal behaviour on Apple M2 Max / macOS 15.6.1; whether Apple classifies the undocumented timing as a defect is unknown. Production remains `unreliable`; no tested nonblocking deferred-resolve topology passes the current-value gate. wgpu#9414 is a separate macOS 26 all-zero symptom | `evaluate_replay.py` mechanism decision tests and strict current-value `candidate_passes`, `evaluate_metal_trace.py`, `gpu_timing_rejects_reversed_timestamps` | `artifacts/timing-mechanism-v1/mechanism-verdict.json`, `m6-enqueued-corrected-evaluation.json`, `m7-order.json`; original `artifacts/timing-replay-v10-f1/evaluation.json` |
| Map callbacks outliving their slot; teardown while registrations are in flight | ingot `gfx` (`gpu_timing.odin`, `screenshot.odin`, `submission.odin`, `context.odin`) | Callback dispatch audit of pinned wgpu-native (inline delivery from `BufferMapAsync`, `QueueSubmit`, `DevicePoll`, `BufferUnmap`/`BufferDestroy`); v10 `CloseWindow` true with `gh.sc`/`gh.cr` 0 | Repaired: owned immutable map records, collector-only retirement, `_gpu_timing_retire`/`context_close -> bool` refuse until every registration is proved terminal, stray callbacks counted | `gpu_timing_stray_callbacks_are_counted_not_published`, `gpu_timing_inline_callback_completes_armed_record`, `gpu_timing_retire_refuses_until_terminal_callback_observed`, `context_close_refuses_while_timing_registration_armed`, `screenshot_stranded_registration_refuses_until_terminal_callback`, `submission_stray_callbacks_are_counted` | `artifacts/timing-game-v10/` (`gh.sc` 0, `gh.cr` 0, exit 0) |
| Slot phase leak: `gh.s` 1175 frames without a free slot after the ownership rewrite | ingot `gfx` `_gpu_timing_frame_begin` | v9 capture: `gh.s` climbing to 1175, timing stopped after the first frames | Repaired: an unsubmitted active slot is abandoned at the next frame begin; `_gpu_timing_frame_abandon` on the no-frame path | `gpu_timing_unsubmitted_frame_frees_its_slot` | `artifacts/timing-game-v9/` (retained failing) |
| Unreconstructable textures: 256-upload atlas budget saturated before frame 1 | ingot `gfx` diagnostic atlas retention | v6: 1482 uploads dropped before frame 1; v7: 1738 uploads, 420,681 bytes, zero drops | Repaired (diagnostics only): budget 2048 with `atlas_dropped_bytes` exported | `gpu_timing_atlas_uploads_are_owned_and_bounded`, `gpu_timing_atlas_submit_seals_upload_prefix`, `gpu_timing_atlas_failure_keeps_submitted_inputs`, `gpu_timing_atlas_draw_tracks_upload_prefix` | `artifacts/timing-game-v6/`, `-v7/` |
| Transport loss: 8 raw lines per 25 s, `fdd` 1173 deliveries dropped in loading, synchronous frame-thread writes | ForgeCore `client/telemetry.odin` | v10 producer stats; v11 `pd`/`pfd`/`pdd`/`wf`/`eo` 0, 49 raw lines, 1505 deliveries | Repaired: eight owned packets, per-frame collection from `game_prepare` (loading included), single writer thread with byte-offset retries, bounded shutdown that refuses (`game_shutdown` false, library kept loaded) when the writer stalls | `telemetry_loading_production_beyond_capacity_is_accounted`, `telemetry_short_writes_advance_by_offset`, `telemetry_encode_overflow_is_withheld`, `telemetry_shutdown_refuses_while_writer_stalls`, `telemetry_invalid_timestamp_identity_decodes` | `artifacts/timing-game-v11/qualification.json`, `artifacts/timing-export-check-v28/` |
| Recording marked truncated by bounded startup absence of the sidecar (`read_errors` 3 in v10) | Aesir `memwatch` telemetry tail | v10 recording `telemetry_health.read_errors` 3 with a complete producer; v11 `startup_absent` 1, `read_errors` 0 | Repaired: `startup_absent` counted separately up to `MAX_TELEMETRY_STARTUP_ABSENT`; `parse_errors`, `resets`, `unfinished_tail` distinguished; one `telemetry_health_incomplete` definition for coverage, bottlenecks and truncation | `telemetry_tail_distinguishes_startup_absence_from_read_errors`, recording/tail tests in `telemetry_tail_test.odin`, `recording_test.odin` | `artifacts/timing-game-v11/recording/` |
| Unknown GPU samples promoted to valid attribution (v6 frame 3 marked valid at 16,275,202 ms) | Aesir `memwatch` `parse_telemetry` | v6 raw `gfd` entry with `v` true; v11 recording `gv` false, `grl` 2 on all records, `gpu_attributed` 0 | Repaired: `rl` decoded into `gpu_reliability`; anything but `gpu_pass`/`reliable` clears `gv`, invalidates raw frames and drops `gg`; legacy lines are `Unknown`; the badge shows the reason | `telemetry_parse_rejects_gpu_timing_without_reliable_scope` | `artifacts/timing-game-v11/qualification.json` (`gpu_reliability` 2) |
| Presentation cadence measured on out-of-order deliveries | Aesir `memwatch` `recording_analysis.odin` | Raw `fd` entries arrive out of frame order (v11 sq 49: 1484, 1486, 1485, 1487) | Repaired: deliveries sorted by (epoch, frame) before intervals and deadline accounting | `recording_orders_deliveries_before_measuring_cadence` | `artifacts/timing-game-v11/control-three-runs.json` |
| Ocean pass timing | ingot `gfx` / PlanetForger world renderer | v6–v10: no ocean pass recorded; v11: `world.ocean` present in 2/1/5 raw frames per run and in the gameplay summary, all rejected as unreliable with the window pass | Not attributed: no ocean replay bundle exists and the reliability verdict is per scope (`gpu_pass`), so ocean inherits `unreliable`; a separate replay is needed before any ocean-specific claim | none | `artifacts/timing-game-v11/timestamp-game-v11-evidence.tel` (sq 46, frames 1422 and 1432) |
| Host unloading library code with backend completion blocks still pending | ForgeCore `host/main.odin` | Pinned wgpu-hal Metal completion block (`wgpu-hal/src/metal/mod.rs:546–564`) runs after `QueueSubmit` returns; v11 exits clean only because every retire returned true | Refusal path: `restart_game`/`reload_game`/`close_window_then_unload` keep the library loaded when `shutdown` or `context_quiesce_gpu` returns false | No automated test (host tests cover the API surface only); the refusal is observable in `capture.log` | `artifacts/timing-game-v11/capture.log` (no refusal) |

### Three-run control baseline (no candidate)

Fixed 2560×1440 world targets, render scale 1, refresh 120 Hz (`hz` 120,
`bt` 8.3333 in the summaries), same v11 binaries and driver for all runs.
Aesir's cadence numbers come from frame-ordered consecutive presentations
(`recording_presentation_intervals`); its `deadline_samples` only count
intervals after a summary record has published the refresh rate, so
`presentation-deadline-all-intervals.json` applies the same 110 % rule to every
consecutive interval in the raw `fd` records.

| Run | Frames | Displayed p50 / mean / p95 (ms) | Aesir deadline misses | All-interval misses | Host CPU p50 (ms) |
|---|---:|---|---:|---:|---:|
| run1 | 1505 | 8.333 / 16.875 / 50.003 | 47 / 91 | 598 / 1499 (39.9 %) | 12.758 |
| run2 | 1547 | 8.333 / 16.365 / 58.333 | 6 / 15 | 561 / 1532 (36.6 %) | 12.418 |
| run3 | 1471 | 8.335 / 16.709 / 58.333 | 24 / 46 | 573 / 1466 (39.1 %) | 12.726 |

Reading: the median interval is one 120 Hz period, but 37–40 % of intervals
miss the 9.17 ms deadline and the mean is two periods, with p95 at six or
seven periods. Host CPU per frame (p50 12.4–12.8 ms) alone exceeds the 8.33 ms
budget, so the presentation cadence is CPU-bound before any GPU question
arises. **The 120 Hz goal is not met.** No candidate build exists; the
diagnostic replays and the CPU-wait native control are excluded from these
numbers. GPU pass timing remains `unreliable`; no tested deferred-resolve
candidate passes the strict current-value gate on this device.

## September 7 Metal counter-publication mechanism (post step 6)

`artifacts/timing-mechanism-v1/` runs the exact v10 frame-11 pass through pure
Metal on the Apple M2 Max / macOS 15.6.1. The source and executable SHA are in
every JSONL header and footer; `run-consistency.json` verifies two 300-iteration
runs per mode agree within 5 %. This is correctness evidence, not performance
evidence and not a production repair.

| Experiment | Run 1 | Run 2 | Mechanism evidence |
|---|---:|---:|---|
| M0, same-command resolve plus CPU publication polling | 299/300 reversed | 299/300 reversed | The in-buffer read gets the prior end sample while CPU polling sees the current end a median 28.5/29.6 us after its GPU timestamp and 19.8/20.8 us after `command.gpuEndTime`; all 600 observations precede the completed handler. |
| M1, unique indices | 64 first-use zero + 236 stale-by-64 | identical | The resolve reads the previous value of the same index, not the latest value from another index; excludes H-D. |
| M2, all four stage boundaries | 298/299 stale fragment pairs | 299/299 stale fragment pairs | Start/end vertex match post-completion CPU values in all 600 iterations; start/end fragment are stale in 596/598 index samples. Publication latency is fragment-stage-specific. |
| M3, measured compute gap 0 | 299/300 reversed | 299/300 reversed | Baseline race. |
| M3, one 64 MiB compute dispatch | 300/300 ordered; 1.717 ms median gap | 300/300 ordered; 1.718 ms | Finite GPU distance removes the race. Every larger gap through 32 dispatches is also 300/300 ordered. This gives a coarse 1.717 ms upper bound, not the minimum required distance. |
| M4, tracked colour-attachment dependency | 295/300 reversed | 299/300 reversed | A real tracked resource dependency does not publish the fragment samples; excludes H-C's resource-hazard explanation. |
| M5, blit-boundary barrier samples | unsupported | unsupported | `supportsCounterSampling(.atBlitBoundary)` is false on this M2 Max, so this candidate shape cannot be tested or used here. |
| M6, initial `enqueued` trial | 299 numerically ordered + one first-use zero | identical | Audit found the resolve buffer alone was enqueued before the render buffer was committed. Instruments then proved 621/621 resolve encoders ran before fragment start. Both begin and end were the prior iteration (598 stale-by-one-index matches/run), so numerical ordering was a false positive. The strict evaluator now rejects both runs. |
| M6, corrected render-then-resolve enqueue order | 293/300 reversed | 290/300 reversed | Explicitly enqueueing render then resolve before committing both preserves queue order but supplies only 6/9 current fragment ends. It fails `candidate_passes`; separate command buffers alone are insufficient. |
| M6, resolve committed from scheduled handler | 299/300 reversed | identical | Host scheduling is too early; merely splitting command buffers does not establish sample publication. |
| M6, resolve committed from completed handler | 300/300 ordered | identical | Completion is sufficient, but this diagnostic topology depends on completion and is not an admitted production candidate. H-B completion-only snapshot semantics remain excluded by the finite in-buffer M3 gap. |
| Controls | same-command 299/300 reversed; completed 300/300 ordered | identical | Reproduces the September 7 attribution with the extended replay. |

M7 is an Instruments Metal System Trace, not an inference from counter values.
`evaluate_metal_trace.py` joins the exported `metal-gpu-intervals` rows by the
labelled command-buffer ID. In 690/690 render/resolve pairs, the resolve blit
starts **after** fragment execution ends: minimum 0.666 us, median 1.125 us,
maximum 5.084 us. Therefore Metal did not schedule the resolve ahead of the
fragment stage; it scheduled it after fragment execution but before that
stage's counter sample became visible to `resolveCounters`.

`mechanism-verdict.json` selects **H-A: late asynchronous fragment-stage counter
publication**. The measured publication lag is 29.1 us median and 42.7 us max
of the two run p95s; M3 proves only that a 1.717 ms measured gap is sufficient.
The values are compatible: M3's first gap step is deliberately much larger
than M0's measured lag. H-B is excluded by finite in-buffer distance; H-C by
the tracked dependency failure and same-command trace order; H-D by the
unique-index result. The M6 audit changed the candidate verdict, not the H-A
mechanism verdict: `candidate` is now null and the conflict explicitly says
that no current pre-completion deferred resolve passed.

This is Metal driver/firmware behaviour: the same application with no wgpu or
ingot code exhibits it. Apple's public `resolveCounters` documentation does
not specify when a stage-boundary sample becomes visible to a following
encoder, so the evidence cannot decide whether Apple classifies it as a driver
defect or unspecified timing. Production remains `unreliable`; no follow-on
production candidate is admitted. A future candidate needs an evidenced,
nonblocking source of at least the required publication distance and must pass
the strict exact replay plus game/Aesir gates before reliability can change.
gfx-rs/wgpu#9414 remains only a related macOS 26 all-zero report, not evidence
of this mechanism.

Artifacts: `evaluation.json`, `sweep.json`, `mechanism-verdict.json`,
`run-consistency.json`; complete M0–M6 JSONLs; corrected M6 runs and
`m6-enqueued-corrected-evaluation.json`; `m6-enqueued-order-audit.json`;
`candidate-gate.json` (closed without admission); the M7 `.trace` bundle and
`m7-{gpu-intervals,application-encoders,command-buffers}.xml`
exports; `m7-order.json` and `m7-encoder-order.csv`. The long-running trace
JSONLs are intentionally incomplete because each process was terminated after
its trace; their trace artifacts, not those JSONLs, are evidence.

## Remaining gates

- Ocean pass replay bundle and attribution (never replayed; see ledger).
- Find a nonblocking topology that supplies real GPU publication distance. No
  M6 pre-completion deferred-resolve topology passed the strict current-value
  gate, so no production candidate is admitted; `rl.g` remains `unreliable`.
- Automated regression for the host refusal path (library kept loaded when a
  retire returns false).
- Complete source-to-installed-binary provenance (including registry crate
  source).
- Concurrent repository revisions changed during investigation. Capture-specific
  source manifests, not current HEAD alone, must be used for reproducibility.

Verification at step 6: 367 gfx tests with diagnostics enabled and disabled;
34 Python tests; assembled telemetry check v28 (15 tests) enabled and disabled;
ForgeCore host tests; 65 Aesir memwatch tests and the ui memory tests.
Post-step-6 mechanism verification: 43 Python tests; Swift replay builds with
`-warnings-as-errors`; two 300-iteration runs for every M0–M6 mode with
per-class repeatability within 5 %; 690 M7 render/resolve pairs parsed from the
exported Instruments table; 621 initial-M6 pairs independently establish the
false-positive queue order; two corrected 300-iteration M6 runs close the
candidate gate without admission.

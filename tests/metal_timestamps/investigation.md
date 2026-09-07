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

## Remaining gates

- Finish first-frame trace metadata and classify all observed labels; gameplay was
  not established in the bounded capture.
- Complete source-to-installed-binary provenance (including registry crate source).
- Callback userdata retirement and shutdown remain unmodified and unsafe in the
  previously identified timeout path. Native reproduction does not excuse this bug.
- Exact minimal WebGPU and window replay, delayed eight-slot inspection, explicit
  status propagation, and repaired end-to-end Aesir validation remain outstanding.
- Concurrent repository revisions changed during investigation. Capture-specific
  source manifests, not current HEAD alone, must be used for reproducibility.

Verification so far: 346 Ingot tests with diagnostics enabled and disabled; focused
ForgeCore identity decode test; 62 Aesir memwatch tests; five Python evaluator tests.
The Aesir startup-missing-sidecar regression reproduces a persistent read error
after later successful reads, but neither fixes production collection nor proves
the historical capture's error was ENOENT. No 120 Hz conclusion.

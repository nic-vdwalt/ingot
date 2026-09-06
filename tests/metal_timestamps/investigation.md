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

Next discriminating control: a separate resolve command submitted only after render
completion, used solely to test publication/ordering. Compare all four counters and
retain clear-only unwritten-stage behavior separately. Then inspect whether an
explicit supported synchronization primitive can provide that visibility without a
CPU stall or workload change. If not, expose unreliable timing rather than changing
measured semantics invisibly.

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
lifetime repairs. 345 gfx tests pass enabled and disabled; four Python evaluator
tests pass. The full repository check currently stops at provenance approval for
six already-tracked isolated build artifacts. The root style scan also traverses
archived source trees; those archives must not be reformatted as production code.

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

Verification so far: 342 Ingot tests with diagnostics enabled and disabled; focused
ForgeCore identity decode test; four Python evaluator tests. No 120 Hz conclusion.

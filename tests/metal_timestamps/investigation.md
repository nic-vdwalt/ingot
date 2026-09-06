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

# Metal timestamp correctness fixtures

These are correctness regressions, not performance acceptance captures. Use Aesir for profiling.

From the Ingot repository:

```sh
swift tests/metal_timestamps/native.swift > artifacts/timestamp-matrix.jsonl
python3 tests/metal_timestamps/evaluate.py artifacts/timestamp-matrix.jsonl \
  --library ../tools/wgpu-455571728/lib/libwgpu_native.a \
  --manifest artifacts/timestamp-matrix-manifest.json
```

The matrix submits 40 offscreen command buffers: four repetitions of drawn,
clear-only, clipped, fragment-discard and depth-only passes, with fresh and reused
counter storage. Every submission is completed before storage inspection/reuse.
The evaluator explicitly checks the known clear-only failure rather than treating
zero or stale fragment counters as valid elapsed time. A changed driver behavior
fails the oracle and requires review; this is not a portable conformance assertion.

On Apple M2 Max/macOS 15.6.1, all eight clear-only passes reproduced unwritten
fragment ends. Drawn, clipped, discard and depth-only cases produced ordered stage
samples. Stage-boundary sampling was supported; draw/blit-boundary sampling was
not. These results do not validate a production repair or prove freshness for all
possible workloads. Window targets, delayed callbacks and the game's production
multi-command-buffer topology remain required follow-up cases.

The fixture now appends a blit encoder with stage timestamps. In the final three
40-submission trials:
- Default empty blit: all 40 post-pass sample pairs remained zero.
- `--copy-boundary`: a 256-byte unrelated buffer copy wrote timestamps, but its
  start overlapped rendering in all 40 cases. Encoding order is not a GPU dependency.
- `--dependent-boundary`: copying the rendered texture to a buffer produced
  ordered post-pass samples in all 40 cases. This introduces a full-target readback
  and changes the workload, so it is not a production timing repair.

A subsequent `--fence-boundary` experiment updates an `MTLFence` after the render
fragment stage, waits for it in the blit encoder, and performs only the unrelated
256-byte copy. Five independent 40-submission trials produced 200 ordered,
nonzero post-boundary pairs, while retaining all 40 expected clear-only failures.
Captures and manifests are `artifacts/timestamp-boundary-fence*.jsonl` and
`artifacts/timestamp-boundary-fence*-manifest.json` (the first trial has no number).
This historical synchronization candidate is not a production repair: later
GPU-resolution controls below failed despite ordered boundary samples. It adds
GPU work/serialization. Do not integrate it. Aesir remains the profiler.

`--fence-boundary --split-commands` separates render and boundary encoders into
80 actual command-buffer submissions for 40 cases. Two trials produced 80 ordered
pairs with no missing or reversed boundaries. This is only a two-buffer fixture,
not yet the complete production topology. Conversely, `--fence-boundary --empty-fence`
removes the copy and produced 39 reversed boundary pairs and one overlapping pair
in 40 cases: a fence alone does not make empty encoder samples trustworthy.
The evaluator now reports reversed pairs separately rather than overlooking them.
These captures are `artifacts/timestamp-fence-split*.jsonl` and
`artifacts/timestamp-fence-empty.jsonl`.

New captures include the running source's SHA-256. The evaluator rejects a source
mismatch before writing a manifest; use `--source` with an archived source when
reviewing older captures. Legacy captures without a source hash explicitly report
`source_identity_verified=false`. Preserved sources are
`artifacts/timestamp-fence-source.swift` (five original fence trials) and
`artifacts/timestamp-split-source.swift` (source-hashed split trial).
Run evaluator regressions with
`python3 -m unittest discover -s tests/metal_timestamps -p 'test_*.py'`.

The evaluator reports missing/overlapping/reversed post-boundary samples without
treating an ordered copy result as validation of pass-duration semantics.

The manifest records fixture/capture/library SHA-256, Ingot revision and tracked
diff hash. The supplied library path is a dependency artifact identity, not proof
that a native Swift probe linked wgpu (it does not). It also does not establish
which library a separately built game linked.

Backend source lookup on 2026-09-06 resolved wgpu-native v29.0.1.1 to commit
`6aed50955d934ac36049ba8d002034841633ae02`. Its Cargo.toml uses registry dependencies
with minimum versions 29.0.1, not a wgpu submodule. The release Cargo.lock actually
selects **29.0.3** for wgpu-hal/core/types. The wgpu-hal registry checksum is
`31f8e1a9e7a8512f276f7c62e018c7fa8d60954303fed2e5750114332049193f`.
The inspected v29.0.3 Metal command source still maps vertex-start to begin and
fragment-end to end. Registry crate/source and binary provenance must still be
verified before claiming an exact binary-source match.

## Render-counter publication controls

The current source resolves only render sample indices 0–3 on the GPU and compares
those values with CPU resolution after completion. The measured interval is index
0 (vertex start) through index 3 (fragment end), not the vertex-only pair 0/1.

```sh
swift tests/metal_timestamps/native.swift --gpu-resolve
swift tests/metal_timestamps/native.swift --gpu-resolve --split-commands
swift tests/metal_timestamps/native.swift --gpu-resolve --split-commands \
  --resolve-after-completion
swift tests/metal_timestamps/native.swift --gpu-resolve --fence-boundary --empty-fence
```

All are correctness-only controls. `--resolve-after-completion` waits on the CPU
before submitting resolution; it is not a production repair. The fence-only
control inserts no copy or dummy draw. Preserve existing artifacts when rerunning.

| Artifact suffix after `artifacts/timestamp-render-` | Cases | GPU/CPU mismatches | Drawn reversed intervals |
|---|---:|---:|---:|
| `range-control.jsonl` | 40 | 40 | 32 |
| `split-nowait-control.jsonl` | 40 | 9 | 1 |
| `completed-control.jsonl` | 40 | 0 | 0 |
| `completed-repeat.jsonl` | 40 | 0 | 0 |
| `range-fence-only-control.jsonl` | 40 | 28 | 21 |

All commands completed without errors. Both completed-render controls retain eight
clear-only reversed intervals despite exact GPU/CPU agreement. The fence-only run
has seven clear mismatches and one reversed GPU clear interval; its CPU samples
have eight reversed clear intervals. Stale but ordered prior-pass arrays also
occur, so checking only interval order cannot establish freshness.

Source archive: `artifacts/timestamp-render-range-source.swift`, SHA-256
`5c0a669410c8770752ca958c3baec32a1ef1e5ff3f4705b1d9e4f78181078467`.
Each of the five JSONL artifacts has an adjacent `-postrun-manifest.json` containing
capture/source/evaluator hashes, verified source identity, device, topology flags
and automated results. These are explicitly post-run verification, not pre-build
provenance; historical compiler and executable identities were not recorded.
Prior source archives and manifests remain unchanged. See `investigation.md` for
the documentation review and limits on attributing these mechanisms to game passes.

Evidence retention does not complete the parent game-reproduction gate. Exact
window/ocean replay, callback retirement, telemetry repair and Aesir qualification
remain outstanding. No native control establishes production timing or 120 Hz.

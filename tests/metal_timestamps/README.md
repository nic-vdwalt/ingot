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
possible workloads. Window targets, delayed callbacks, multiple encoders per
submission and the game's production topology remain required follow-up cases.

The manifest records fixture/capture/library SHA-256, Ingot revision and tracked
diff hash. The supplied library path is a dependency artifact identity, not proof
that a native Swift probe linked wgpu (it does not). It also does not establish
which library a separately built game linked.

Backend source lookup on 2026-09-06 resolved wgpu-native v29.0.1.1 to commit
`6aed50955d934ac36049ba8d002034841633ae02`. Its Cargo.toml uses registry dependencies
wgpu-hal/core/types 29.0.1, not a wgpu submodule. Inspect Cargo.lock and crate source
checksums before asserting an exact binary/source match or building a patch.

Step 1 remains in progress. Do not treat fixture completion as implementation of
the six-step profiling plan.

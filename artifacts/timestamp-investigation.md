# Metal timestamp reproduction

## Confirmed mechanism

Apple M2 Max, macOS 15.6.1 (24G90), wgpu v29.0.1 backend source.

`timestamp_native.swift` bypasses Ingot and WebGPU. It alternates a full-screen triangle render pass with a clear-only render pass, waits for command completion, and resolves all four Metal stage samples.

Drawn passes update vertex and fragment timestamps. Clear-only passes update vertex timestamps but leave fragment timestamps unchanged from the prior drawn pass (or zero on a fresh sample buffer). All command buffers report no error.

Example:

```
frame=0 [187413152167291,187413152180458,187413152180666,187413152201750]
frame=1 [187413153355541,187413153373666,187413152180666,187413152201750]
```

The checked wgpu backend (`metal-command-v29.rs`, lines 991–1004) maps render-pass start to start-of-vertex and render-pass end to end-of-fragment. This creates a reversed pair for a clear-only pass when the counter set is reused. Waiting for completion cannot write a stage that never executes.

## Rejected experiments

- Separate resolve submission: PlanetForger still produced 1,304 invalid frames.
- Encoder-boundary window timing: minimal clear-only probe retained 211 valid / 28 invalid frames; insufficient and changes timing semantics.
- Fresh query sets: minimal probe retained 98 valid / 141 invalid frames, replacing stale fragment ends with zeros.
- Wait before separate resolution: 0 valid / 239 invalid frames.
- Baseline clear-only pass timestamps: 1 valid / 238 invalid frames.

Experimental renderer changes were removed. Diagnostic fields remain. Probe artifacts are diagnostic, not acceptance-grade foreground performance captures.

## Repair requirement

Do not clamp, substitute zero, or assume an end-of-vertex sample measures fragment execution. A correct backend solution needs separately recorded vertex/fragment stage ends, selecting only stages demonstrably written in the current generation, or a reliable explicitly ordered post-pass sampling operation. It must preserve real render-pass duration for drawn, clear-only, fully clipped, and depth-only workloads. Avoid dummy draws in production as they alter measured work.

The native reproduction establishes an empty-stage failure mechanism; it does not yet prove every PlanetForger invalid frame has this cause. Preserve full diagnostics and test every pass topology before declaring step 1 complete.

# Causal ledger: Aesir GPU timing, transport and presentation cadence

Local publication for the plan "From evidence instrumentation to an
attributable game failure" (2026-09-07). Every row cites the artifact that
proves it; nothing here is a performance claim. Verification commands are in
README.md; narrative in investigation.md.

## Qualification capture

`artifacts/timing-game-v11/` is the fresh immutable capture: frozen union
sources (`prebuild-inputs.json`, 850 files hashed), matched host and library
built by the pinned control compiler against the pinned wgpu archive
(`identity-audit.json`), captured by the current driver
(`artifacts/timestamp-aesir-capture-v7`, built from Aesir HEAD with the step 5
tail). `qualification.json` is Aesir's own reading of the recording
(`tests/metal_timestamps/qualify/main.odin` links Aesir's `memwatch`):

| Check | Result |
|---|---|
| Recording complete, not truncated | true |
| Telemetry health | 0 read errors, 0 parse errors, 0 resets, 0 unfinished tail, 1 bounded startup-absent tick |
| Loading through gameplay coverage | 51 records, delivery frames 1..1505 contiguous, 0 packet drops, queue high water 2 |
| Exact identity joins | 0 conflicting identities, 0 sequence gaps or duplicates |
| GPU attribution | 231 raw GPU frames all rejected, 0 attributed; reliability `unreliable`, reason `metal_same_command_buffer_resolve` |
| Callback and worker retirement | host `CloseWindow` true, `game_shutdown` true, writer joined (process exit 0) |
| Presentation cadence (frame order) | p50 8.333 ms, mean 16.9 ms, p95 50.0 ms; 47 of 91 gameplay deadline samples missed |

Three-run control on the same binaries (`control-three-runs.json`,
`control-run2/`, `control-run3/`): every run complete with clean health and
rejected GPU attribution; displayed p50 8.33 ms, mean 16.4–16.9 ms, p95 50–58 ms,
host CPU p50 12.4–12.8 ms. There is no production candidate build or admitted
diagnostic candidate; no 120 Hz claim.

## Symptom table

| Symptom | Owning layer | Evidence | Fix or limitation | Regression | Artifact |
|---|---|---|---|---|---|
| Reversed / zero GPU pass ends in the game's window pass | Metal stage-boundary publication on Apple M2 Max / macOS 15.6.1: same-command-buffer `resolveCounters` returns the previous fragment sample while vertex samples are current | Exact v10 replay plus M0–M7: publication median 29.1 us after the fragment-end timestamp; one measured 1.717 ms compute gap removes all reversals; tracked colour dependency does not; Instruments shows 690/690 same-command resolve blits start after fragment execution | H-A, late asynchronous fragment-stage counter publication in Metal's driver/firmware. Whether Apple calls the undocumented timing a defect is unknown. No production repair or admitted candidate: strict current-value checks reject every M6 pre-completion deferred resolve, target remains `unreliable`, and Aesir rejects attribution. wgpu#9414 is a separate macOS 26 all-zero symptom | `evaluate_replay.py` mechanism decision tests and strict `candidate_passes`; `evaluate_metal_trace.py`; Aesir reliability rejection | `artifacts/timing-mechanism-v1/mechanism-verdict.json`, `m6-enqueued-corrected-evaluation.json`, `m7-order.json`; original `artifacts/timing-replay-v10-f1/` |
| Timing map callbacks published into mutable slot state; shutdown destroyed readback buffers after a bounded poll regardless | Ingot `gfx/gpu_timing.odin` | Pinned dispatch audit: callbacks fire inline from MapAsync, QueueSubmit, DevicePoll, Unmap and Destroy | Owned immutable `Gpu_Timing_Map_Request` records, explicit slot phases, retire/quarantine, release refused while armed | `gpu_timing_stray_callbacks_are_counted_not_published`, `gpu_timing_retire_refuses_until_terminal_callback_observed`, `gpu_timing_inline_callback_completes_armed_record`, `gpu_timing_failed_callbacks_complete_out_of_order` | `artifacts/timing-game-v10/signature-comparison.json` (signature unchanged before/after) |
| Screenshot map callback targeted a popped stack frame on timeout | Ingot `gfx/screenshot.odin` | Deferred `BufferDestroy` after `_screenshot_map` returned delivered `Aborted` into a dead frame | `Screenshot_Map` owned by the context; a stranded registration keeps its staging buffer and refuses later captures | `screenshot_stranded_registration_refuses_until_terminal_callback` | gfx tests |
| Undrained submissions at close crashed via `ensure` | Ingot `gfx/context.odin`, `gfx/submission.odin` | `_close_window_context` destroyed resources before draining | Retire submissions, screenshot and timing first; `context_close`/`CloseWindow`/`app_destroy`/`fit.Destroy` return refusal; `context_quiesce_gpu` for hosts | `context_close_refuses_while_timing_registration_armed`, `context_quiesce_does_not_close`, `submission_stray_callbacks_are_counted` | gfx tests |
| Host unloaded the game library with backend work and a writer thread outstanding | ForgeCore `host/main.odin`, `shared/game_api.odin` | Library links its own wgpu copy: `nm build/game.dylib` lists `_wgpuQueueSubmit`, `_gfx::_submission_done`; writer thread lives in the library | `Game_Shutdown_Proc -> bool`; reload deferred until `context_quiesce_gpu`; `ensure` before unload; refused close keeps the library | host tests build; ForgeCore telemetry `telemetry_shutdown_refuses_while_writer_stalls` | v11 exit 0 |
| Timing slots stranded in `Recording` after no-frame branches | Ingot `gfx/gpu_timing.odin` | v9 capture: `gh.s` 1175, one invalid timestamp then silence | Abandon leftover active slot in `_gpu_timing_frame_begin` and in `context_end_drawing`'s no-frame branch | `gpu_timing_unsubmitted_frame_frees_its_slot` | `artifacts/timing-game-v9/` retained as failing evidence |
| Loading produced no telemetry; deliveries dropped (`fdd` 1173); eight-line burst at shutdown | ForgeCore `client/telemetry.odin` | v10 sidecar: 8 raw lines in 25 s | Single-consumer packet transport: per-frame collection on every screen, worker-only encoding and I/O, byte-offset writes, persistent drop/queue/write accounting, terminal packet and bounded join | `telemetry_loading_production_beyond_capacity_is_accounted`, `telemetry_short_writes_advance_by_offset`, `telemetry_encode_overflow_is_withheld`, `telemetry_shutdown_refuses_while_writer_stalls` | v11: 49 raw + 2 summary lines, `pd` 0, `qh` 2 |
| Aesir marked every recording truncated (`read_errors` 1–3) | Aesir `memwatch_darwin.odin` | Sidecar opened before the library created it; every absence counted as a read error | Bounded startup absence (`startup_absent`, not a loss); parse errors, oversized lines, resets and unfinished tails distinguished; one `telemetry_health_incomplete` definition | `telemetry_tail_distinguishes_startup_absence_from_read_errors`, `telemetry_tail_reports_unfinished_final_line`, `recording_retains_structured_telemetry_health` | v11 `telemetry_health`, `z: false` |
| Aesir promoted ordered but stale GPU durations (e.g. 16,275,202 ms) to valid frames | Aesir `parse_telemetry` | v6 raw `gfd` marked valid with absurd durations | GPU timing accepted only when the target declares scope `gpu_pass` reliable; legacy absence is Unknown; deliveries stay valid; badge shows the reason code | `telemetry_parse_rejects_gpu_timing_without_reliable_scope` | v11 `qualification.json`: 231 rejected, 0 attributed |
| Aesir measured presentation cadence on completion order and lost the refresh rate on raw lines | Aesir `recording_analysis.odin` | v11 first pass: 20 false gaps, 0 deadline samples | Deliveries sorted by (epoch, frame); refresh rate carried from the last summary | `recording_orders_deliveries_before_measuring_cadence` | v11 `qualification.json`: 1499 intervals, 1 gap |
| Ocean pass timing | Ingot `gfx` / PlanetForger world renderer | v6–v10 had no ocean category; v11 records `world.ocean` in 2/1/5 raw frames per run and in gameplay summaries, but all GPU samples are rejected under the scope-wide reliability verdict | Observed but not attributed; requires its own replay bundle before an ocean-specific claim | none | `artifacts/timing-game-v11/timestamp-game-v11-evidence.tel` |
| Sustained 120 Hz presentation | Unmeasured against a production candidate | Control: p50 8.33 ms, mean 16.4–16.9 ms, p95 50–58 ms; 37–40 % of all consecutive intervals miss the 9.17 ms deadline; host CPU p50 12.4–12.8 ms | No production candidate exists; performance work starts from this control with fixed 2560x1440 world targets and scale 1 | `control-three-runs.json`, `presentation-deadline-all-intervals.json` | `artifacts/timing-game-v11/` |

## What is not claimed

- No GPU pass duration from this backend is trustworthy on the inspected
  device; every capture carries `unreliable` and Aesir attributes none.
- The render-completed resolve control and the replay programs are diagnostic
  only and are excluded from any performance number.
- 120 Hz is not achieved: the control runs miss roughly half of their gameplay
  deadlines and CPU frame time alone exceeds the 8.33 ms budget.

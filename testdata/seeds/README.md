# Fuzz regression corpus

This directory contains small, minimized operation tapes that must replay successfully after their defect is fixed. `manifest.json` is authoritative; unlisted `.ingtape` files fail validation.

Create a tape with `fuzz/run.sh TARGET SEED ITERATIONS` plus the target binary's `-record:path` option, reproduce it with `-replay:path`, minimize a structured invariant failure with `-shrink:path -shrink-output:path`, then add the minimized tape and metadata together. Do not commit random bulk fuzz output.

Tape replay is stable across generator changes. In-process shrinking supports returned invariant failures; sanitizer crashes and assertions support exact replay but require external process isolation before they can be minimized safely.

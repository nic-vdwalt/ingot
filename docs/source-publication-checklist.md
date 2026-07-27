# Source publication checklist

This checklist governs making the Git source repository public. It does not
authorize native binaries, installers, web bundles, or production-readiness
claims; those remain governed by `oss-release-checklist.md` and
`production-readiness.md`.

## Completed technical evidence

- [x] Repository code is offered under Apache License 2.0.
- [x] Reachable history contains no generated build trees, generated demo/fuzz
  executables, or superseded patched font.
- [x] Reachable-history credential scanning found only the documented local WSS
  fixture keys in `testdata/wss`.
- [x] All tracked ignored files were removed and the hygiene gate runs in CI.
- [x] Committed binary/font artifacts and checksums are recorded in
  `provenance/third-party-artifacts.json`.
- [x] JetBrains Mono 2.304 has complete OFL provenance.
- [x] Exact libvterm 0.3.3 source and license are committed in `vendor/libvterm`.
- [x] AccessKit release archive inputs and the macOS transformation are recorded.
- [x] The TigerStyle adaptation retains its modified-work attribution.
- [x] Test certificates, style/context baselines, and generated benchmark policy
  are documented in `provenance/fixtures.md`.
- [x] Public contribution, security, issue, and pull-request guidance exists.

## Owner confirmations required

- [x] Nicolas van der Walt confirmed ownership or an Apache-2.0-compatible grant
  for all original and Alloy-derived source on 2026-07-26.
- [x] Nicolas van der Walt confirmed on 2026-07-26 that no employment,
  contractor, assignment, or other agreement prevents publication under
  Apache-2.0.
- [x] Git history contains one contributor identity, Nicolas van der Walt's
  GitHub identity; no non-owner contribution grants are currently required.
- [x] GitHub private vulnerability reporting was approved and enabled on
  2026-07-26.

## Before changing repository visibility

- [x] Complete the owner confirmations above.
- [x] Coordinate the history cutover described in `history-rewrite.md`.
- [x] Run `scripts/check.sh`, `scripts/test.sh`, and `scripts/check-web.sh` from a
  fresh clone of rewritten history.
- [x] Confirm GitHub branch protection is enabled.
- [x] Confirm GitHub private vulnerability reporting is enabled.

Binary and web releases additionally require the deferred toolchain, linked
library, SDK, runtime-notice, SBOM, platform-validation, and counsel-review work
in `oss-release-checklist.md`.

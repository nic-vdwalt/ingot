# Contributing to Ingot

Ingot welcomes focused fixes, tests, documentation, and features that preserve
its immediate-mode ownership model and bounded-work guarantees. Discuss broad
API or architecture changes in an issue before investing in an implementation.

## Development setup

Use the pinned Odin toolchain from `README.md` and put both `odin` and
`odinfmt` on `PATH`. Clone the repository with its full contents, then run:

```sh
bash scripts/check.sh
bash scripts/test.sh
bash scripts/check-web.sh
```

The portable CI matrix covers macOS, Linux, and Windows. Some GPU, accessibility,
dialog, browser, and platform-polish checks require the hardware or interactive
environment described in `docs/production-readiness.md`.

## Engineering rules

Read `AGENTS.md` and `docs/TIGER_STYLE.md`. In particular:

- safety comes before performance and developer experience;
- callers own persistent state and frame work is bounded;
- recursion and unbounded queues or loops are not accepted;
- wire, file, and FFI boundaries use explicitly sized types;
- operating errors are handled and programmer errors are asserted;
- changed procedures meet the assertion, 100-line, 100-column, and formatting
  gates enforced by `scripts/check.sh`.

Add deterministic tests for behavior changes. Start with the affected package,
then run the complete native, strict, and web gates. Include reproducible seeds
for fuzz failures and do not weaken a baseline to conceal a new finding.

## Pull requests

Keep each pull request scoped to one coherent change. Explain the motivation,
platform impact, user-visible behavior, and test evidence. Update documentation
when an API, compatibility boundary, or support claim changes.

New dependencies, fonts, generated data, static libraries, and other assets must
include their exact version or revision, upstream source, license, notices,
SHA-256, and reproducible build or extraction steps. Update
`docs/provenance/third-party-artifacts.json` when adding a tracked binary or any
file of at least 1 MiB. The repository hygiene gate rejects unexplained large
artifacts and generated outputs.

## Licensing submissions

By submitting a contribution, you agree that it is offered under the repository's
Apache License 2.0, without additional terms. You must have the right to submit
the work. Identify copied, adapted, generated, employer-owned, or third-party
material in the pull request and retain all required attribution and notices.
This policy applies to new submissions and does not make claims about historical
contributions.

Report vulnerabilities through the private process in `SECURITY.md`, not in a
public issue.

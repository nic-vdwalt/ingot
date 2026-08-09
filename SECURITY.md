# Security policy

## Supported versions

`0.1.5` is the latest source release. Security fixes land on `main` first and
are included in a replacement source tag when a release is required; older tags
do not receive separate maintenance branches. Source availability does not imply
production or binary-release readiness; review `docs/production-readiness.md`
before deploying Ingot in a security-sensitive application.

## Reporting a vulnerability

Use GitHub's **Report a vulnerability** flow in the repository Security tab to
open a private security advisory. Do not disclose exploit details, credentials,
private reports, or an unpatched vulnerability in a public issue or discussion.
If private vulnerability reporting is unavailable, wait for the repository
owner to publish an approved private contact rather than posting details.

Include the affected revision and platform, impact, reproduction steps or a
minimal proof of concept, relevant logs, and any suggested mitigation. Remove
secrets and personal data from evidence.

The maintainer will acknowledge a report when it is reviewed, coordinate scope
and remediation with the reporter, and agree on disclosure timing after a fix
or mitigation is available. Response and release times depend on severity and
maintainer availability; no fixed service-level commitment is currently made.
Good-faith reporters will be credited if they request it and disclosure is safe.

Public issue templates are appropriate for non-sensitive crashes and correctness
bugs only.

# Public history rewrite

On 2026-07-26, unpublished repository history was rewritten to remove generated
Cargo build trees, demo and fuzz executables, and the superseded patched font.
The local backup is `../ingot-pre-public-rewrite-2026-07-26.bundle`; keep it
private and delete it after the public cutover is accepted.

The rewritten refs must replace their remote counterparts deliberately:

```sh
git push --force-with-lease origin main feat/ingot-net feat/ingot-webgpu
git push --force origin \
  refs/tags/archive/mine-wip \
  refs/tags/archive/stash-7c0afdb \
  refs/tags/archive/stash-cb9c3b1 \
  refs/tags/archive/verify-wip
```

Do not run those commands until collaborators have stopped pushing and the
remote backup policy is confirmed. After the cutover, collaborators must clone
again rather than merge old history. The rewrite reduced the local pack from
about 71 MiB to about 19 MiB. A reachable-history scan found only the three
intentional, localhost-only TLS private-key fixtures documented in
`testdata/wss/README.md`.

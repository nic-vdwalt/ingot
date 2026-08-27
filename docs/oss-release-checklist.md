# Binary and web release checklist

The root Apache-2.0 license covers Ingot's original work. It does not relicense
third-party binaries, fonts, documentation, toolchain code, or system
libraries. Complete `source-publication-checklist.md` before making the Git
repository public. Complete this additional checklist before publishing a
native binary, installer, or web bundle.

## Original-code ownership

- [ ] Confirm Nicolas van der Walt or the named licensor owns the copyright in
  all Ingot contributions, including code moved from the Alloy Odin client.
- [ ] Confirm no employment, contractor, or assignment agreement prevents
  licensing those contributions under Apache-2.0.
- [ ] Review every non-owner contribution and retain its license or obtain an
  Apache-2.0-compatible grant.

## Bundled artifacts

- [x] Record the exact tagged source and build inputs for every committed
  AccessKit and libvterm archive.
- [ ] Capture the AccessKit 0.22.3 Rust dependency license inventory and ship
  all required notices with binary distributions.
- [x] Restore and document the exact libvterm 0.3.3 source used by the build
  scripts, including its license.
- [x] Verify committed artifact checksums against the release manifest.
- [x] Remove generated executables from source releases.

## Bundled font

- [x] Replace the patched Nerd Fonts artifact with unmodified JetBrains Mono
  Regular 2.304 from the official tagged release.
- [x] Record the tagged source, commit, archive path, retrieval date, and
  SHA-256 checksums in `THIRD_PARTY_NOTICES.md`.
- [x] Remove Nerd Fonts private-use icon ranges and dependencies.
- [x] Keep `assets/fonts/OFL.txt` with every distribution containing the font.

## Source provenance

- [ ] Compare `gfx/raymath.odin`, `gfx/rlgl/rlgl.odin`, and related rendering
  code against the raylib versions that informed their API. If implementation
  or comments were translated, retain raylib's zlib notice and mark changes.
- [x] Retain the modified-work attribution at the top of
  `docs/TIGER_STYLE.md`.
- [x] Review test certificates, fixtures, and generated data for documented
  provenance and regeneration steps.

## Toolchain and release output

- [ ] Inventory licenses in the pinned Odin toolchain and all vendor packages
  used by the release.
- [ ] Include notices for GLFW, stb, miniaudio, WebGPU/wgpu-native, libcurl,
  and any other code linked or copied into release output.
- [ ] Include applicable Odin and WebGPU runtime notices in web distributions;
  mark the staged `wgpu.js` compatibility transformation.
- [ ] Review platform SDK and runtime redistribution terms for each binary
  target.
- [ ] Generate an SBOM and archive it with release evidence.
- [ ] Record the exact package composition and prove minimal GUI artifacts do
  not link optional terminal, networking, AccessKit, ECS, scene, or procedural
  generation packages they do not import.
- [ ] Archive end-to-end benchmark inputs and runtime evidence separately;
  compile-only fixtures are not performance evidence.

## Final verification

- [ ] Run `bash scripts/check.sh`.
- [ ] Run `bash scripts/test.sh`.
- [ ] Run `bash scripts/check-web.sh` for web release candidates.
- [ ] Verify `LICENSE`, `NOTICE`, and `THIRD_PARTY_NOTICES.md` are included in
  source archives, binary packages, and installers.
- [ ] Review the final license inventory with qualified counsel before the
  first public release.

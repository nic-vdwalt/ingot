# Text and asset dependency policy

Ingot does not add a text-shaping or SVG dependency merely to match another UI
framework. The current shared native/web path remains the supported default:
`vendor:stb/truetype` rasterizes scalar codepoints into bounded WebGPU atlases,
and `vendor:stb/image` decodes raster images supplied as bytes. Complex-script
shaping, bidirectional layout, font fallback, ligatures, general SVG, and
animated-image playback are not currently claimed.

This is an explicit scope decision, not silent approximation. A feature can be
approved later when a concrete Ingot application requires it and the complete
safety and reproducibility case is stronger than retaining the narrow behavior.

## Decision

No new shaping, SVG, or animated-image dependency is approved now.

If rich shaping becomes a committed requirement, the preferred architecture is
one pinned, source-vendored implementation shared by native and WebAssembly. OS
text APIs may remain optional host backends, but cannot define canonical layout
because platform-dependent metrics would make wrapping, caret movement,
selection, screenshots, and deterministic tests disagree.

A from-scratch general OpenType shaper or SVG engine is also rejected for now.
Pure Odin removes an FFI boundary but does not remove the standards size, parser
attack surface, or correctness burden.

Applications that need SVG today should preprocess it into pinned raster assets
or supply bounded RGBA data. Applications requiring unsupported scripts must use
an explicitly owned specialist text path rather than rely on incorrect scalar
layout.

## Dependency approval gate

A future proposal must satisfy every item before implementation begins.

### Provenance and licensing

- Pin an exact upstream version and source revision.
- Record source and artifact SHA-256 values.
- Commit source or verified artifacts so normal builds require no network.
- Record licenses and transitive obligations in `THIRD_PARTY_NOTICES.md`.
- Add every binary or large artifact to the repository provenance manifest.

### Reproducible native and web builds

- Build every supported native target and `js_wasm32` from the same source and
  feature configuration.
- Pin compilers, linkers, flags, and archive behavior.
- Remove timestamps and host paths; CI must verify reproducible checksums.
- Preserve the existing no-dynamic-discovery default path.

### FFI and ownership

- Keep foreign types behind a small Odin-owned adapter.
- Use fixed-width sizes at every ABI boundary.
- Check pointer/length pairs before crossing the boundary and after return.
- Pair every allocation with one explicit release procedure.
- Never retain frame scratch or temporary Odin pointers in foreign callbacks.
- Return explicit operating errors for malformed or unsupported data.

### Named bounds

The proposal must name conservative defaults and hard maxima for all applicable
input bytes, faces, runs, glyphs, clusters, fallback depth, OpenType features,
SVG nodes, nesting depth, path segments, frames, dimensions, decoded bytes, and
work per call. Traversal must be iterative.

### Security and verification

- Add dedicated malformed-font/shaping and image/SVG fuzz targets as applicable.
- Run foreign code under native sanitizers and replay the same corpus in Wasm.
- Commit minimized deterministic regressions.
- Test invalid UTF-8, adversarial Unicode, missing glyphs, atlas exhaustion,
  malformed dimensions, decompression limits, and parser saturation.
- Add a real web fixture plus Wasm size and memory budgets.
- Record native and browser runtime evidence before publishing support claims.

## Existing boundary

The current renderer measures and draws from the same codepoint atlas, ensuring
that scalar measurement describes scalar rendering. UI caches are keyed by the
font epoch and are reset when the backend or DPI changes. Raster path loading is
native-only; browser applications fetch bytes and use the common memory decoder.

These facilities remain valid for their documented scope. Extending the scope
requires a new design review because shaped clusters affect rendering, wrapping,
truncation, hit testing, caret movement, selection, IME, markdown, accessibility
offsets, atlas keys, and cache invalidation together.

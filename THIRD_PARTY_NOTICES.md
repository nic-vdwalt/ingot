# Third-party notices

Ingot's original source is licensed under Apache License 2.0. The components
listed below are independent works and retain their own licenses. This file is
informational and does not replace their license terms.

## AccessKit C API 0.22.3

Bundled files:

- `accesskit/include/accesskit.h`
- `accesskit/lib/darwin_arm64/libaccesskit.a`
- `accesskit/lib/darwin_amd64/libaccesskit.a`
- `accesskit/lib/linux_amd64/libaccesskit.a`
- `accesskit/lib/windows_amd64/accesskit.lib`

Source: <https://github.com/AccessKit/accesskit-c/releases/tag/0.22.3>

The source and release inputs are contained in `accesskit-c-0.22.3.zip`:

```text
b652e380fb78efe6721ad892f15b2224f38f661c3fb20436ef4c5b3ce0fe8177  accesskit-c-0.22.3.zip
```

Copyright 2023 The AccessKit Authors. All rights reserved.

AccessKit C is offered under Apache License 2.0 or the MIT License. Ingot
redistributes it under the Apache License 2.0 option. The complete license is
in `LICENSE`. The macOS archives are transformed by
`scripts/build-accesskit.sh` into prelinked, debug-stripped archives exporting
AccessKit symbols; they are not byte-identical to upstream release artifacts.

SHA-256:

```text
02fd1544b972a0217b56f0e975b242c1d729d5a80638c5d9ed51cd5b4df9180a  accesskit/lib/darwin_arm64/libaccesskit.a
4c0b0c1d614a30b3137567bc54634d9c93f55abea8b55596294bed754feb3fc2  accesskit/lib/darwin_amd64/libaccesskit.a
b3cb0b7055f3e4cd30d21dca9778f956d49503ef0088d5a7fee8600929e8b70b  accesskit/lib/linux_amd64/libaccesskit.a
376fceabd2da5860d5fc11cadc5958027875b711445c1c406c387d74529659c2  accesskit/lib/windows_amd64/accesskit.lib
c7e0dff6b97ba5793d5a092d6ef817d5a4ec5ffe409345f5927fc0da4b06cf61  accesskit/include/accesskit.h
```

The committed release archives are Rust static libraries. The upstream
lockfile and a derived 162-crate inventory with upstream's enforced licence
allow-list are in `docs/provenance/accesskit-c-0.22.3.Cargo.lock` and
`docs/provenance/accesskit-rust-dependencies.md`. Before distributing binary
releases, generate the per-crate notice text from that lockfile as described
there and ship it with the binary.

## libvterm 0.3.3

Bundled files:

- `libvterm/lib/darwin_arm64/libvterm.a`
- `libvterm/lib/darwin_amd64/libvterm.a`
- `libvterm/lib/windows_amd64/vterm.lib`

Linux archives are generated on the native target from the same pinned,
patched vendored source by `scripts/check-linux-dependencies.sh`; they are build
outputs rather than committed release artifacts.

Source: <https://www.leonerd.org.uk/code/libvterm/libvterm-0.3.3.tar.gz>

The exact upstream source is committed under `vendor/libvterm`. The source
archive SHA-256 is
`09156f43dd2128bd347cbeebe50d9a571d32c64e0cf18d211197946aff7226e0`;
the corresponding mirror tag points to commit
`9d6d2112335080312ef8c36667fa717ded4f7daf`. Build the archives with
`scripts/build-libvterm.sh` or `scripts/build-libvterm.bat`.

### Local modifications

The vendored source is upstream 0.3.3 with four robustness patches
applied. All were found by fuzzing the `term` package, which now fences them:

- `src/screen.c`, `erase_internal()`: skip cells for which `getcell()` returns
  `NULL` instead of writing through the null pointer. The row loop bounds
  against `screen->state->rows` while `getcell()` checks `screen->rows`, and
  the column loop is not bounded by `screen->cols` at all, so an erase rect
  derived from the state can outrun the screen buffer while the two disagree.
  Interleaving `term_resize` with `term_pump` reaches this and segfaults. It
  was found by `fuzz/run.sh term`, which now fences it. The guard uses the
  same `if(!cell)` idiom the rest of the file already applies to `getcell()`
  results.

- `src/encoding.c`, `decode_utf8()`: do not emit two codepoints when only one
  slot remains. The ASCII branch writes the U+FFFD marker for an abandoned
  multi-byte sequence and then the character itself, but the loop guard only
  proves room for one, so landing that pair on the last slot wrote one `uint32`
  past the end of `vt->tmpbuffer`. The overrun is silent: it corrupts the C
  heap and the process aborts later in an unrelated `free`. Any terminal output
  containing a truncated UTF-8 sequence can reach it, and it made
  `scripts/test.sh` abort roughly 43% of the time. The fix stops without
  consuming the byte so the caller re-enters with an empty buffer, which is the
  same partial-consumption path already used for text runs longer than the
  codepoint buffer.

- `src/screen.c`, `putglyph()`: stop writing continuation cells for a
  double-width glyph once `getcell()` returns `NULL`. A wide glyph placed on
  the final column has no room for its continuation cell, so `getcell()`
  returns `NULL` for it, and the unconditional dereference of that result was
  undefined behaviour: the compiler is entitled to elide `getcell()`'s bounds
  checks and emit a direct write one cell past the screen buffer, which is
  exactly what clang does on linux_amd64 at `-O2`. It surfaced as a
  deterministic `Segmentation_Fault` in `term.fuzz_vterm_ingest` in Linux CI
  and is fenced by `term.vterm_wide_glyph_on_last_column_stays_in_bounds`. The
  guard uses the same `if(!cell)` idiom the rest of the file already applies
  to `getcell()` results.

- `src/state.c`, `on_text()`: clamp negative codepoint widths to zero.
  `vterm_unicode_width()` returns -1 for C1 controls (U+0080..U+009F) that
  arrive as UTF-8 text, and adding that to the cursor column moved the cursor
  to -1 and emitted a damage rect with `end_col < start_col`; a following
  resize then failed to place the cursor. It surfaced as
  `term.term_pump_resize_fuzz` failing in Windows CI with seed
  `1790829414776857500` and is fenced by
  `term.vterm_c1_control_text_keeps_cursor_in_grid`.

Any upstream refresh must re-apply these patches or confirm upstream has fixed
them. Both macOS archives have been rebuilt from the patched source and their
checksums updated in `docs/provenance/third-party-artifacts.json`.
`scripts/build-libvterm.sh` sets `ZERO_AR_DATE=1` so a rebuild of identical
source reproduces the recorded checksum byte for byte; without it `ar` stamps
each member with the build time and the manifest would only ever match the one
machine that produced it.

The Windows archive includes all four patches. It was imported from successful
Windows workflow run `38216972728`, artifact `11731239833`
(`windows-libvterm-patched`), built from Ingot revision
`8cd2d9447d81139efd387be46378abefc6363fd0`. It predates the additional REP
progress fix described below.
Its SHA-256 was verified against the artifact's `vterm.lib.sha256` sidecar;
that run passed both native and SDL3 test gates with this archive.

The v0.4.0 tag still contains the older unpatched archive; this replacement is
post-release work, first included in the 0.4.1 tag, and does not move that
tag.

An additional `state.c` `on_csi` REP fix ignores nonpositive saved glyph widths.
Otherwise repeating a zero-width glyph never advances the cursor and hangs the
parser. Windows fuzz seed `1791872852732517200` reproduced the hang locally;
after the fix all 300 iterations completed in approximately 250 ms.
`term.vterm_repeat_zero_width_makes_progress` covers empty, C1 and combining
prefixes and verifies normal ASCII repetition afterward. Both macOS archives
include this fix. The Windows archive still needs a native rebuild; the local
host lacks MSVC/UCRT headers. Windows CI rebuilds before testing until that
replacement is available. Windows run `38360454882` at revision
`0114b41579db30e7287e0b996e0b3fdeab67ab0c` rebuilt and uploaded the fixed
archive, but failed in `ui.layout_facade_button_key_paths` before reaching
terminal tests; it is not successful Windows runtime evidence. Run
`38367410585` at the 0.4.1 tag
`6e87b46bff2f268b0685f9fcd17f5e4837865b49` passed with a rebuilt archive and
uploaded it as artifact `11796654538`. The committed archive remains unchanged
pending a validated replacement.
The hygiene gate verifies checksums, not source correspondence. For future
archive replacements:

1. Download `windows-libvterm-patched` from a green run, or run
   `scripts\build-libvterm.bat` on Windows.
2. Copy `vterm.lib` over `libvterm/lib/windows_amd64/vterm.lib` and confirm
   the SHA-256 matches `vterm.lib.sha256` when using the CI artifact.
3. Run `python3 scripts/record-artifact-checksum.py libvterm/lib/windows_amd64/vterm.lib`;
   it rewrites the checksum below and in
   `docs/provenance/third-party-artifacts.json`, sets `built_from` to
   `patched`, and removes the `stale` note.
4. Run `python3 scripts/check-repository-hygiene.py` and commit the archive
   with both manifests.

The MIT License

Copyright (c) 2008 Paul Evans <leonerd@leonerd.org.uk>

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.

SHA-256:

```text
63589ada3a115e5fc79610f746996972cd250831f380b9cc89fcc0b7cf0ef383  libvterm/lib/darwin_arm64/libvterm.a
7c1163513fd8da5881033572bbcc61fc1804e49bb52bcf6e60236d268144b084  libvterm/lib/darwin_amd64/libvterm.a
8c07e3362a6e056b372417f950dc000d262ad3db9c54c2f78332380e5a6fd03d  libvterm/lib/windows_amd64/vterm.lib
```

## JetBrains Mono Regular 2.304

Bundled file:

- `assets/fonts/JetBrainsMono-Regular.ttf`

Source: <https://github.com/JetBrains/JetBrainsMono/releases/tag/v2.304>

The file is `fonts/ttf/JetBrainsMono-Regular.ttf` from the official
`JetBrainsMono-2.304.zip` release archive at commit
`cd5227bd1f61dff3bbd6c814ceaf7ffd95e947d9`. It was retrieved on 2026-07-26
without modification. Upstream did not publish a checksum or signature for the
archive; the repository records the verified local hashes below.

SHA-256:

```text
6f6376c6ed2960ea8a963cd7387ec9d76e3f629125bc33d1fdcd7eb7012f7bbf  JetBrainsMono-2.304.zip
a0bf60ef0f83c5ed4d7a75d45838548b1f6873372dfac88f71804491898d138f  assets/fonts/JetBrainsMono-Regular.ttf
30f0c136e3c88e422d0791acd97238870f9054a9729bc34cf2ff0d4ed8cac4ad  assets/fonts/OFL.txt
```

Copyright 2020 The JetBrains Mono Project Authors
(<https://github.com/JetBrains/JetBrainsMono>).

JetBrains Mono is licensed under SIL Open Font License 1.1. The complete
copyright notice and license are in `assets/fonts/OFL.txt`. The font declares
no Reserved Font Names in that file. It is separately licensed and is not
covered by Ingot's Apache-2.0 grant.

## Pixel Operator Regular 2018.10.04-1

Bundled file:

- `assets/fonts/PixelOperator.ttf`

Source: <https://www.dafont.com/pixel-operator.font>

The file is `PixelOperator.ttf` from the `pixel_operator.zip` archive of
release 2018.10.04-1, retrieved on 2026-09-27 without modification. The
archive's `LICENSE.txt` is stored as `assets/fonts/PixelOperator-LICENSE.txt`
with its line endings converted from CRLF to LF. Upstream did not publish a
checksum or signature for the archive; the repository records the verified
local hashes below.

SHA-256:

```text
95b33667e4884f5714db33d8324472df28f9d5ffed49108824c5819c1a217dad  pixel_operator.zip
8d805274eaf227855147153182a96a86ff395ddbc7d2d378095af8831b764a3e  assets/fonts/PixelOperator.ttf
a2010f343487d3f7618affe54f789f5487602331c0a8d03f49e9a7c547cf0499  assets/fonts/PixelOperator-LICENSE.txt
```

Pixel Operator is made by Jayvee Enaguas (HarvettFox96) and is dedicated to
the public domain under Creative Commons Zero (CC0) 1.0 Universal. The full
dedication is in `assets/fonts/PixelOperator-LICENSE.txt`.

## TigerBeetle TigerStyle

`docs/TIGER_STYLE.md` is an Odin-focused adaptation of TigerBeetle's
TigerStyle document:
<https://github.com/tigerbeetle/tigerbeetle/blob/main/docs/TIGER_STYLE.md>.

The upstream document is licensed under Apache License 2.0. The complete
license is in `LICENSE`. Ingot's adaptation is marked as modified in the file.
The upstream repository did not include a `NOTICE` file when this notice was
prepared.

## Odin toolchain and linked dependencies

Ingot imports packages from the pinned Odin toolchain, including WebGPU,
GLFW, stb, miniaudio, and X11 bindings, and links libcurl and platform system
libraries on applicable targets. These dependencies are not relicensed by
Ingot. Binary distributors must inventory and include the notices applicable
to the exact pinned Odin toolchain and linked libraries.

`scripts/stage-web-runtime.sh` copies and modifies Odin and WebGPU JavaScript
runtime files into consumer builds. Distributors of those builds must preserve
the applicable upstream notices and identify the modified runtime file.

## API compatibility

Parts of `ingot:gfx` intentionally expose a raylib-shaped API to simplify
migration. API compatibility does not imply that raylib is bundled.

Comparison record (2026-10-10): `gfx/raymath.odin` and `gfx/rlgl/rlgl.odin`
were compared against the raylib bindings shipped with the pinned Odin
toolchain (`vendor/raylib/raymath.odin`, `vendor/raylib/rlgl/rlgl.odin`;
zlib/libpng licence, Copyright (c) 2013-2026 Ramon Santamaria). Only procedure
names and parameter shapes coincide. `raymath.odin` holds 31 lines of
elementary vector arithmetic written directly; `rlgl/rlgl.odin` holds
forwarders onto `ingot:gfx` plus six OpenGL enum constants whose values come
from the OpenGL specification. No raylib implementation, comment, or
documentation text was translated, so raylib's zlib notice is not required for
these files. Both files carry a header line crediting the API names to raylib.
Repeat the comparison whenever either file gains code that is not a forwarder.

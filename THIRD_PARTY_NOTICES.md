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

Copyright 2023 The AccessKit Authors. All rights reserved.

AccessKit C is offered under Apache License 2.0 or the MIT License. Ingot
redistributes it under the Apache License 2.0 option. The complete license is
in `LICENSE`. The macOS archives are transformed by
`scripts/build-accesskit.sh` into prelinked archives exporting AccessKit
symbols; they are not byte-identical to upstream release artifacts.

SHA-256:

```text
4b0f56c6852856ea91790318976f9b06c8ce61afdecfc3e4e5eef955a50ac46c  accesskit/lib/darwin_arm64/libaccesskit.a
ab7aad4f73228ca03f6c2bdf50ff23c25a8831672dea738a0edf3bc967eb3391  accesskit/lib/darwin_amd64/libaccesskit.a
b3cb0b7055f3e4cd30d21dca9778f956d49503ef0088d5a7fee8600929e8b70b  accesskit/lib/linux_amd64/libaccesskit.a
376fceabd2da5860d5fc11cadc5958027875b711445c1c406c387d74529659c2  accesskit/lib/windows_amd64/accesskit.lib
c7e0dff6b97ba5793d5a092d6ef817d5a4ec5ffe409345f5927fc0da4b06cf61  accesskit/include/accesskit.h
```

The committed release archives are Rust static libraries. Before distributing
binary releases, capture and ship the exact 0.22.3 archive's complete
transitive dependency license inventory.

## libvterm 0.3.3

Bundled files:

- `libvterm/lib/darwin_arm64/libvterm.a`
- `libvterm/lib/darwin_amd64/libvterm.a`
- `libvterm/lib/windows_amd64/vterm.lib`

Source: <https://www.leonerd.org.uk/code/libvterm/>

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
d028977b50a95813fc60638aa27c7877ab838af6c6f572f5cec28466e1e0d57f  libvterm/lib/darwin_arm64/libvterm.a
42907dad31c644e9b4f2568bc9e8e86a33bfc3669035f7e93bb5b4c0d3e9e6bb  libvterm/lib/darwin_amd64/libvterm.a
726100141eba902aeef49ee134ea3b88767f558ef691d35091526ae29d89e369  libvterm/lib/windows_amd64/vterm.lib
```

The build scripts refer to `vendor/libvterm`, which is not currently committed.
Restore the exact 0.3.3 source and its file-level notices before claiming
reproducible binary provenance.

## JetBrains Mono Nerd Font Mono Regular

Bundled file:

- `assets/fonts/JetBrainsMonoNerdFontMono-Regular.ttf`

SHA-256:

```text
f01031f40e48dc29e1112e6b0b0450a2c6cd097f3f35cfff05c55cb311f8034c  assets/fonts/JetBrainsMonoNerdFontMono-Regular.ttf
```

The base font is JetBrains Mono:
<https://github.com/JetBrains/JetBrainsMono>.

Copyright 2020 The JetBrains Mono Project Authors.

The base font is licensed under SIL Open Font License 1.1. The complete
copyright notice and license are in `assets/fonts/OFL.txt`. JetBrains Mono
declares no Reserved Font Names in that file.

The file is a patched Nerd Fonts artifact:
<https://github.com/ryanoasis/nerd-fonts>.

Nerd Fonts patched fonts carry this notice:

Copyright (c) 2014, Ryan L McIntyre (<https://ryanlmcintyre.com>).

Nerd Fonts combines icon glyphs governed by several licenses, including MIT,
Apache-2.0, SIL OFL 1.1, and CC BY 4.0. Its license audit also identifies Font
Logos as unlicensed. The exact Nerd Fonts release used for this artifact is not
recorded, so this repository cannot yet provide a reliable glyph-by-glyph
license inventory.

Do not distribute this font in a release until its exact tagged source and
complete icon notices have been established, or replace it with a font whose
full redistribution chain is known. The font remains separately licensed and
is not covered by Ingot's Apache-2.0 grant.

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
migration. API compatibility does not imply that raylib is bundled. Before a
release, complete the source-comparison item in `docs/oss-release-checklist.md`
to confirm that no translated raylib implementation requiring its zlib notice
is present.

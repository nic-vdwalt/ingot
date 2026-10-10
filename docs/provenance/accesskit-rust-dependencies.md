# AccessKit C 0.22.3 Rust dependency inventory

Ingot links the prebuilt `accesskit-c` 0.22.3 release archives recorded in
`THIRD_PARTY_NOTICES.md`. Those archives are Rust static libraries, so a binary
distribution of an application that imports `ingot:accesskit` (through
`ingot:ui_gfx`) also redistributes the transitive Rust crates below.

Source of truth: `accesskit-c-0.22.3.Cargo.lock` in this directory, copied
verbatim from the upstream tag archive
(<https://github.com/AccessKit/accesskit-c/archive/refs/tags/0.22.3.zip>).
It resolves 162 packages. Upstream `deny.toml` for the same tag enforces the
licence allow-list below in its CI (`cargo deny check`), which is why every
crate in the lockfile falls under one of these licences:

- Apache-2.0
- Apache-2.0 WITH LLVM-exception
- BSD-2-Clause
- BSD-3-Clause
- ISC
- MIT
- Zlib
- Unicode-DFS-2016 (exception granted for `unicode-ident` only)

## Target applicability

`accesskit-c` selects its platform adapter with `cfg(target_os)` gates:
`accesskit_macos` on macOS, `accesskit_unix` on Linux and the BSDs,
`accesskit_windows` on Windows, `accesskit_android` and `accesskit_ios` on
targets Ingot does not ship. The column below is derived from those gates and
from each crate's position in the dependency graph; it is a reading aid, not a
build output. The authoritative per-target set is
`cargo tree --target <triple> --edges normal` against the committed lockfile.
Crates marked `all` are platform-independent core dependencies
(`accesskit`, `accesskit_consumer`, serde, hashing, macro support).

| Crate | Version | Target |
|---|---|---|
| `accesskit` | 0.24.1 | all |
| `accesskit-c` | 0.22.3 | all |
| `accesskit_android` | 0.7.5 | Android/iOS (not shipped) |
| `accesskit_atspi_common` | 0.19.1 | Linux |
| `accesskit_consumer` | 0.38.0 | all |
| `accesskit_ios` | 0.1.2 | Android/iOS (not shipped) |
| `accesskit_macos` | 0.26.3 | macOS |
| `accesskit_unix` | 0.22.1 | Linux |
| `accesskit_windows` | 0.34.0 | Windows |
| `async-broadcast` | 0.7.1 | Linux |
| `async-channel` | 2.3.1 | Linux |
| `async-executor` | 1.13.1 | Linux |
| `async-fs` | 2.1.2 | Linux |
| `async-io` | 2.3.4 | Linux |
| `async-lock` | 3.4.0 | Linux |
| `async-process` | 2.3.0 | Linux |
| `async-recursion` | 1.1.1 | Linux |
| `async-signal` | 0.2.10 | Linux |
| `async-task` | 4.7.1 | Linux |
| `async-trait` | 0.1.83 | Linux |
| `atomic-waker` | 1.1.2 | Linux |
| `atspi` | 0.29.0 | Linux |
| `atspi-common` | 0.13.0 | Linux |
| `atspi-proxies` | 0.13.0 | Linux |
| `autocfg` | 1.1.0 | all |
| `bitflags` | 2.6.0 | all |
| `block2` | 0.5.1 | macOS |
| `blocking` | 1.6.1 | Linux |
| `bytes` | 1.11.1 | Linux |
| `cesu8` | 1.1.0 | Linux |
| `cfg-if` | 1.0.0 | all |
| `cfg_aliases` | 0.2.1 | all |
| `combine` | 4.6.7 | Linux |
| `concurrent-queue` | 2.5.0 | Linux |
| `crossbeam-utils` | 0.8.15 | Linux |
| `endi` | 1.1.0 | Linux |
| `enumflags2` | 0.7.10 | Linux |
| `enumflags2_derive` | 0.7.10 | Linux |
| `equivalent` | 1.0.1 | all |
| `errno` | 0.3.9 | Linux |
| `event-listener` | 5.3.1 | Linux |
| `event-listener-strategy` | 0.5.2 | Linux |
| `fastrand` | 2.1.1 | Linux |
| `foldhash` | 0.2.0 | all |
| `futures-core` | 0.3.31 | Linux |
| `futures-io` | 0.3.31 | Linux |
| `futures-lite` | 2.6.0 | Linux |
| `futures-macro` | 0.3.31 | Linux |
| `futures-task` | 0.3.31 | Linux |
| `futures-util` | 0.3.31 | Linux |
| `hashbrown` | 0.16.1 | all |
| `hermit-abi` | 0.4.0 | Linux |
| `hex` | 0.4.3 | Linux |
| `indexmap` | 2.11.4 | all |
| `jni` | 0.21.1 | Android/iOS (not shipped) |
| `jni-sys` | 0.3.0 | Android/iOS (not shipped) |
| `libc` | 0.2.159 | all |
| `linux-raw-sys` | 0.4.14 | Linux |
| `log` | 0.4.29 | all |
| `memchr` | 2.5.0 | all |
| `memoffset` | 0.9.1 | Linux |
| `nix` | 0.29.0 | Linux |
| `objc-sys` | 0.3.5 | macOS |
| `objc2` | 0.5.2 | macOS |
| `objc2-app-kit` | 0.2.2 | macOS |
| `objc2-cloud-kit` | 0.2.2 | macOS |
| `objc2-contacts` | 0.2.2 | macOS |
| `objc2-core-data` | 0.2.2 | macOS |
| `objc2-core-image` | 0.2.2 | macOS |
| `objc2-core-location` | 0.2.2 | macOS |
| `objc2-encode` | 4.1.0 | macOS |
| `objc2-foundation` | 0.2.2 | macOS |
| `objc2-link-presentation` | 0.2.2 | macOS |
| `objc2-metal` | 0.2.2 | macOS |
| `objc2-quartz-core` | 0.2.2 | macOS |
| `objc2-symbols` | 0.2.2 | macOS |
| `objc2-ui-kit` | 0.2.2 | Android/iOS (not shipped) |
| `objc2-uniform-type-identifiers` | 0.2.2 | macOS |
| `objc2-user-notifications` | 0.2.2 | macOS |
| `once_cell` | 1.19.0 | all |
| `ordered-stream` | 0.2.0 | Linux |
| `parking` | 2.2.1 | Linux |
| `phf` | 0.13.1 | all |
| `phf_generator` | 0.13.1 | all |
| `phf_macros` | 0.13.1 | all |
| `phf_shared` | 0.13.1 | all |
| `pin-project-lite` | 0.2.13 | Linux |
| `pin-utils` | 0.1.0 | Linux |
| `piper` | 0.2.4 | Linux |
| `polling` | 3.7.3 | Linux |
| `proc-macro-crate` | 3.2.0 | Linux |
| `proc-macro2` | 1.0.106 | all |
| `quick-xml` | 0.36.2 | Linux |
| `quote` | 1.0.37 | all |
| `rustix` | 0.38.37 | Linux |
| `same-file` | 1.0.6 | Linux |
| `serde` | 1.0.210 | all |
| `serde_derive` | 1.0.210 | all |
| `serde_repr` | 0.1.19 | Linux |
| `signal-hook-registry` | 1.4.1 | Linux |
| `siphasher` | 1.0.2 | all |
| `slab` | 0.4.8 | Linux |
| `static_assertions` | 1.1.0 | Linux |
| `syn` | 2.0.87 | all |
| `tempfile` | 3.13.0 | Linux |
| `thiserror` | 1.0.69 | all |
| `thiserror-impl` | 1.0.69 | all |
| `toml_datetime` | 0.6.8 | Linux |
| `toml_edit` | 0.22.24 | Linux |
| `tracing` | 0.1.40 | Linux |
| `tracing-attributes` | 0.1.27 | Linux |
| `tracing-core` | 0.1.32 | Linux |
| `uds_windows` | 1.1.0 | Linux |
| `unicode-ident` | 1.0.8 | all |
| `uuid` | 1.19.0 | all |
| `walkdir` | 2.5.0 | Linux |
| `winapi` | 0.3.9 | Windows |
| `winapi-i686-pc-windows-gnu` | 0.4.0 | Windows |
| `winapi-util` | 0.1.11 | Linux |
| `winapi-x86_64-pc-windows-gnu` | 0.4.0 | Windows |
| `windows` | 0.62.2 | Windows |
| `windows-collections` | 0.3.2 | Windows |
| `windows-core` | 0.62.2 | Windows |
| `windows-future` | 0.3.2 | Windows |
| `windows-implement` | 0.60.2 | Windows |
| `windows-interface` | 0.59.3 | Windows |
| `windows-link` | 0.2.1 | Windows |
| `windows-numerics` | 0.3.1 | Windows |
| `windows-result` | 0.4.1 | Windows |
| `windows-strings` | 0.5.1 | Windows |
| `windows-sys` | 0.45.0 | Windows |
| `windows-sys` | 0.52.0 | Windows |
| `windows-sys` | 0.59.0 | Windows |
| `windows-targets` | 0.42.2 | Windows |
| `windows-targets` | 0.52.6 | Windows |
| `windows-threading` | 0.2.1 | Windows |
| `windows_aarch64_gnullvm` | 0.42.2 | Windows |
| `windows_aarch64_gnullvm` | 0.52.6 | Windows |
| `windows_aarch64_msvc` | 0.42.2 | Windows |
| `windows_aarch64_msvc` | 0.52.6 | Windows |
| `windows_i686_gnu` | 0.42.2 | Windows |
| `windows_i686_gnu` | 0.52.6 | Windows |
| `windows_i686_gnullvm` | 0.52.6 | Windows |
| `windows_i686_msvc` | 0.42.2 | Windows |
| `windows_i686_msvc` | 0.52.6 | Windows |
| `windows_x86_64_gnu` | 0.42.2 | Windows |
| `windows_x86_64_gnu` | 0.52.6 | Windows |
| `windows_x86_64_gnullvm` | 0.42.2 | Windows |
| `windows_x86_64_gnullvm` | 0.52.6 | Windows |
| `windows_x86_64_msvc` | 0.42.2 | Windows |
| `windows_x86_64_msvc` | 0.52.6 | Windows |
| `winnow` | 0.7.3 | Linux |
| `xdg-home` | 1.3.0 | Linux |
| `zbus` | 5.5.0 | Linux |
| `zbus-lockstep` | 0.5.2 | Linux |
| `zbus-lockstep-macros` | 0.5.2 | Linux |
| `zbus_macros` | 5.5.0 | Linux |
| `zbus_names` | 4.2.0 | Linux |
| `zbus_xml` | 5.0.2 | Linux |
| `zvariant` | 5.4.0 | Linux |
| `zvariant_derive` | 5.4.0 | Linux |
| `zvariant_utils` | 3.2.0 | Linux |

## Remaining release work

Per-crate licence text is not generated here because the repository pins no
Rust toolchain. Before shipping a binary that links AccessKit, run on any
machine with `cargo` and `cargo-about` installed:

```sh
cd accesskit-c-0.22.3   # unpacked upstream tag archive
cargo about init
cargo about generate --all-features --config about.toml -o accesskit-notices.html about.hbs
```

Review the output against this inventory, then ship it with the binary
alongside `LICENSE`, `NOTICE`, and `THIRD_PARTY_NOTICES.md`. Repeat when
`accesskit-c` is upgraded, and replace both files in this directory with the
new tag's lockfile and derived table.

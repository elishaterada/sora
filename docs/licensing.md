# Licensing Notes

This file records preliminary engineering guidance, not legal advice.

## Ghostty / GhosttyKit

Inspected source: [`ghostty-org/ghostty`](https://github.com/ghostty-org/ghostty)
commit [`c81f0b26871c7fbbe2fc35549fdad1f64ed29094`](https://github.com/ghostty-org/ghostty/commit/c81f0b26871c7fbbe2fc35549fdad1f64ed29094).

| Field | Value |
| --- | --- |
| License identifier | MIT |
| License URL | https://github.com/ghostty-org/ghostty/blob/main/LICENSE |
| Copyright | Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors |
| Embedding form | Static archive inside `GhosttyKit.xcframework` (`libghostty-internal.a`) |
| Header used | `include/ghostty.h` (internal embedder API) |

MIT obligations for this project:

1. Keep the copyright notice and permission notice in all copies or substantial
   portions of Ghostty that we distribute.
2. Include that notice in the repository (this file and a future
   `NOTICE` / `ThirdPartyNotices` document).
3. Include that notice in the application bundle before any public binary
   release.
4. Linking a static MIT library into a proprietary or differently licensed app
   is generally permitted; it does not copyleft Sora. Confirm with counsel
   before a public release.

The API we depend on is labeled internal and "not designed for external use."
That is an engineering stability risk, not a license prohibition. Mitchell
Hashimoto has stated that commercial products already embed this API
([Libghostty Is Coming](https://mitchellh.com/writing/libghostty-is-coming)).

Do not copy Ghostty's Swift UI (`macos/Sources/...`) wholesale. Study
lifecycle and callback wiring, then write a thin Sora host. If any Ghostty
Swift file is later adapted, keep its MIT header and record the file in
notices.

### Bundled third-party components inside GhosttyKit

Ghostty's Zig build statically combines several upstream libraries into
`libghostty-internal.a` ([`build.zig.zon`](https://github.com/ghostty-org/ghostty/blob/main/build.zig.zon),
[`GhosttyLib.zig`](https://github.com/ghostty-org/ghostty/blob/main/src/build/GhosttyLib.zig)).
A non-exhaustive list that must be inventoried before public distribution:

| Component | Upstream | Typical license | Notes |
| --- | --- | --- | --- |
| FreeType | `pkg/freetype` | FTL and/or GPLv2 | FTL is the usual embedding choice; verify the copy Ghostty compiles |
| HarfBuzz | `pkg/harfbuzz` | MIT / Old MIT | |
| fontconfig | `pkg/fontconfig` | MIT | |
| zlib | `pkg/zlib` | zlib | |
| libpng | `pkg/libpng` | libpng | |
| oniguruma | `pkg/oniguruma` | BSD-2-Clause | |
| simdutf | `pkg/simdutf` | Apache-2.0 / MIT dual | |
| Highway | `pkg/highway` | Apache-2.0 | |
| Wuffs | `pkg/wuffs` | Apache-2.0 | |
| glslang / SPIRV-Cross | shader translation | various | compiled into the renderer stack |
| JetBrains Mono | font dependency | SIL OFL 1.1 | OFL is not MIT; bundling the font files has attribution/rename rules |
| Nerd Fonts Symbols | font dependency | OFL / MIT mix | confirm whether glyphs ship in the archive or only as a build input |

**Human review required before any public binary:** produce a complete
`ThirdPartyNotices` file from the exact Ghostty commit we ship, including
fonts and shader translators. Phase 1 may build locally without finishing
that audit, but must not silently drop Ghostty's MIT notice.

Ghostty's `src/shell-integration/zsh/ghostty-integration` is GPLv3 (it started
as Kitty's script). Sora does not copy that file into application source; it
ships inside Ghostty's bundled resource tree. Counsel should confirm that
redistributing those scripts with the app is acceptable before a public
release.

Source distribution: MIT does not require publishing Sora source. If a
GPLv2-only file from FreeType (or another dependency) is compiled in under
GPL rather than FTL, obligations change. Verify which FreeType license
Ghostty's build actually uses.

## Ghostling

Ghostling is MIT ([LICENSE](https://github.com/ghostty-org/ghostling/blob/main/LICENSE),
Copyright (c) 2026 Mitchell Hashimoto). It is a research reference only.
Do not copy `main.c` into Sora. Ghostling's PTY and Raylib renderer are
the opposite of the chosen GhosttyKit path.

## Warp

Warp may be studied for publicly visible behavior, UX patterns, and architectural ideas. Do not copy implementation code into Sora without explicit human approval and a license review.

Treat AGPL-covered code as unavailable for direct reuse in this project unless the project owner deliberately accepts the resulting obligations.

## Vercel fx

`fx` is a design and architecture reference only. Sora must not require it at runtime. If code is ever adapted, review the exact file and repository license first and preserve all required notices.

## Community wrappers

Do not add [`lakr233/libghostty-spm`](https://github.com/lakr233/libghostty-spm)
or similar wrappers in V0. They wrap the same GhosttyKit API and add another
license to track.

## Sparkle

Sora uses Sparkle 2.9.6 for signed, in-place application updates. Sparkle is
MIT-licensed and includes small components under compatible licenses. Xcode
resolves the package from `sparkle-project/Sparkle`; the release packager copies
Sparkle's complete `LICENSE` into every distribution as
`Sparkle-LICENSE.txt`.

Sparkle is used instead of an application-owned installer because safely
replacing and relaunching a running macOS app requires privileged-location,
atomic replacement, signature-validation, and recovery behavior. Update
archives and the feed are signed with a dedicated EdDSA key. The public key is
embedded in Sora; the private key is held in the maintainer's login Keychain
and the `SPARKLE_ED_PRIVATE_KEY` GitHub Actions secret, never in the repository.

## Other dependencies

For each added dependency, document:

- purpose
- version or commit
- license
- why an Apple-native or existing dependency does not meet the need
- distribution obligations

Do not add a dependency solely to avoid writing a small, stable adapter.

Phase 1 expected third-party set:

| Dependency | Purpose | License |
| --- | --- | --- |
| GhosttyKit from pinned Ghostty commit | terminal core | MIT plus bundled notices above |
| Sparkle 2.9.6 | signed application replacement and relaunch | MIT plus bundled notices |
| Apple SDK (Swift, SwiftUI, AppKit, Metal) | host app | Apple |

Sparkle is the only Swift package dependency.

## Release gate

Before any public binary or source release:

1. audit dependency licenses
2. produce a third-party notices file
3. verify app-bundle attribution
4. review the public product name separately
5. obtain qualified legal review for any consequential uncertainty


### Optional SSH shell-integration export (2026-09-12)

The export includes unmodified Ghostty Bash/zsh shell scripts from the pinned
commit above. Their GPLv3-or-later headers remain intact; the complete GPLv3
license accompanies the scripts as source. Bash's existing bash-preexec 0.7.0
helper is MIT; its full notice was verified against the upstream version's
[LICENSE.md](https://github.com/rcaloras/bash-preexec/blob/0.7.0/LICENSE.md) and is
included. Sora's separate adapters call those hooks without copying their
implementation. No new runtime library was added. Existing public-release
license review requirements remain in force.

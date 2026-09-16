# Sora 0.5.0 release verification

Prepared from `cc3e95c` on the published main branch, in an isolated checkout.
Only tab interaction changes, their tests/docs, the version/changelog, and the
completion fix discovered by Release tests are included. Unrelated local Agent,
skin, README, and media work is excluded.

## Build and tests

- Apple Silicon Release suite: **381 tests passed**.
- Clean Debug suite before the completion expression adjustment: **382 tests passed**.
- Development workspace suite (including unrelated in-progress tests): 388 passed.
- Packaging uses `MARKETING_VERSION=0.5.0 CURRENT_PROJECT_VERSION=25
  SKIP_GHOSTTY_BUILD=1 Scripts/package-app.sh` with the existing Ghostty build.
- `codesign --verify --deep --strict` and bundle version/build checks are required
  on the final packaged and publicly downloaded app.

The initial Release suite and a focused rerun failed
`CommandCompletionTests.testSupportedContextsAndShellSyntaxFallback`: the
optimized test inserted `git log '--max-count='` instead of the expected
unquoted flag. Replacing the bound CharacterSet method reference with an
explicit closure retained the same allowed characters and quoting rules and
made the complete Release suite pass. A small standalone optimized reproduction
did not fail; the observation is specific to the full optimized target, not a
claim about all Swift compilation. Existing tests cover the regression.

## Native checks

- The user verified immediate pointer switching and Command-hold hints in the
  development build.
- Packaged Release smoke check: Command–1/2 select the corresponding tabs;
  Command–9 with two tabs preserves selection.
- Earlier native checks verified switching from Agent input, double-click
  renaming, drag reordering, and current output after returning to a hidden tab.

## Commands

```sh
xcodebuild -project Sora.xcodeproj -scheme Sora -configuration Release \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/sora-release-tests \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES -parallel-testing-enabled NO test
MARKETING_VERSION=0.5.0 CURRENT_PROJECT_VERSION=25 SKIP_GHOSTTY_BUILD=1 \
  Scripts/package-app.sh
Scripts/extract-release-notes.sh 0.5.0
```

Publication and public artifact checks follow `docs/releasing.md`. Artifacts
remain ad-hoc signed, without Apple notarization. Next issue: shortcut hints
when the sidebar is collapsed.

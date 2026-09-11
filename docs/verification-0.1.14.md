# Sora 0.1.14 verification

- `zig build test -Dtest-filter=Sora -Demit-macos-app=false` in
  `Vendor/ghostty`: passed, including failure status, reflow, and repeated
  archive replay at different widths. The existing block tests also passed.
- `Scripts/build-ghosttykit.sh`: rebuilt the final patch successfully.
- `xcodebuild -project Sora.xcodeproj -scheme Sora -configuration Debug
  -destination 'platform=macOS' -parallel-testing-enabled NO test`:
  262 tests, zero failures.
- `MARKETING_VERSION=0.1.14 SKIP_GHOSTTY_BUILD=1 Scripts/package-app.sh`:
  Apple Silicon Release build and archive succeeded. Local package reports
  version 0.1.14, build 1; CI assigns the public build number.
- `codesign --verify --deep --strict` on the packaged app: passed.
- `Scripts/extract-release-notes.sh 0.1.14`: reviewed the user-facing notes.
- `git diff --check` and reverse-application check of the Ghostty patch: passed.

Manual checks in the Release app: an exit-1 command tinted its command and
output; the following successful command stayed neutral; a failed command
printing 60 lines retained the matching pinned header while scrolling.

No new known issues or decisions requiring review. Existing distribution
limitation remains: ad-hoc signing, without Apple notarization. Command status
highlighting depends on shell integration reporting OSC 133 completion status.

Next recommended issue: add an accessibility description for failed command
blocks so their exit state is available beyond color.

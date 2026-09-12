# Releasing Sora

This is the required release path for every Sora version. `AGENTS.md` points
here so a new task or coding thread follows the same cycle.

## 1. Prepare the version

1. Choose the next semantic version.
2. Set `MARKETING_VERSION` in the Xcode project to that exact version.
3. Add a `## X.Y.Z — YYYY-MM-DD` section at the top of `CHANGELOG.md`.
4. Write for people using Sora. Prefer short “What’s new” and “Fixes” sections
   that explain the benefit. Avoid raw commit messages, file names, and internal
   architecture unless users need them.
5. Run `Scripts/extract-release-notes.sh X.Y.Z` and review the result as the
   text a user will see.

The release workflow deliberately fails when the matching changelog section is
missing or empty.

## 2. Verify the build

1. Run the complete test suite.
2. Build the Release configuration for Apple Silicon.
3. Confirm the packaged app reports the intended marketing version and build.
4. Verify its code signature and manually exercise the changed user path when
   practical.
5. Check the working-tree diff for accidental or unrelated changes.

## 3. Publish

1. Commit the version, changelog, code, tests, and documentation together.
2. Push the commit to `main`.
3. Create and push an annotated `vX.Y.Z` tag on that commit.
4. Wait for `.github/workflows/release.yml` to finish successfully.

The workflow packages the app, signs the archive, embeds the matching Markdown
changelog in the signed Sparkle appcast, and creates the GitHub Release using
the same highlights. Existing users therefore see what changed in the native
update-review window before choosing Install; visitors see it on GitHub above
the download instructions.

## 4. Verify the public release

Do not call the release complete until all of these are true:

- GitHub’s latest release resolves to the new `vX.Y.Z` tag.
- The release is published, not a draft, with readable highlights followed by
  installation guidance.
- The Apple Silicon zip and `appcast.xml` are both downloadable.
- The appcast contains the new short version, build number, archive URL,
  non-empty EdDSA signature, and the Markdown changelog description.
- `main`, the version tag, and the local checkout point at the intended commit.

Release artifacts are currently ad-hoc signed and not Apple-notarized. Keep the
first-open Gatekeeper guidance on the release page until distribution moves to
Developer ID signing and notarization.

## Build cache

The Ghostty cache includes a checkout with Sora's renderer patch already applied.
Its key must include both the build script and patch hashes. Do not restore an
older patch revision through a broad fallback key: neither applying the new
patch nor reverse-checking it against the old patched tree is reliable. A patch
change starts a fresh cache and rebuilds GhosttyKit.

# Repository privacy review — September 13, 2026

Reviewed all 85 public commits, all 23 release tags, tracked examples and test
fixtures, historical file versions, commit/tag metadata, evaluation reports, and
image assets. Local working files and local-only snapshot objects were also
reviewed. These local snapshots are not published GitHub history.

Gitleaks 8.30.1 found no credentials in the public history. Manual inspection
identified personal fixture names, home-directory examples, a personal website
in URL tests and verification notes, and personal commit/tag email metadata.

## Cleanup

- Replaced personal fixture values with neutral examples in
  CommandRunFactoryTests.swift, WorkspaceModelTests.swift, and WebpageTests.swift.
- Omitted the personal URL from the historical verification account in ai-ask.md.
- Replaced author, committer, and tagger identity with the public GitHub handle
  and GitHub no-reply email.
- Rewrote every affected historical commit and release tag, not just the latest
  file versions. Public repository URLs and required third-party attribution
  remain intact.
- Configured this checkout to use the GitHub no-reply identity for future commits.

All rewritten commit trees were compared with the originals: only the intended
privacy replacements changed. The credential scan and targeted personal-data
scan were repeated after rewriting. The Sora scheme built and the existing
test suite passed with the neutral fixtures.

The release workflow is paused during the tag replacement, then restored, to
avoid rebuilding or replacing already-signed release assets. This is a history
cleanup, not a new release.

## Limits and follow-up

Secret scanning and manual review cannot prove that a repository contains no
sensitive information. Public GitHub attribution remains intentional.

Rewriting branches and tags removes the old data from their browsable history.
Old commit URLs, cached views, existing clones, and forks can retain it.
GitHub Support controls server-side cache removal and garbage collection.
Other clones must be freshly cloned or carefully rebased; merging old history
can reintroduce the removed data.

Use fictional names, reserved example domains, and synthetic fixture content
for future tests. Check screenshots visually before committing them. Keep
credentials in Keychain or the appropriate secret store.

See GitHub's [sensitive-data removal guidance](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/removing-sensitive-data-from-a-repository).

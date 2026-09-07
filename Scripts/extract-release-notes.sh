#!/bin/bash

set -euo pipefail

VERSION="${1#v}"
CHANGELOG="${2:-CHANGELOG.md}"

if [[ -z "${VERSION}" ]]; then
  echo "error: a release version is required" >&2
  exit 1
fi

if [[ ! -f "${CHANGELOG}" ]]; then
  echo "error: changelog not found: ${CHANGELOG}" >&2
  exit 1
fi

if ! NOTES="$(
  awk -v version="${VERSION}" '
    $0 ~ "^## " version "([[:space:]]|$)" { found = 1; next }
    found && /^## [^#]/ { exit }
    found && (started || NF) { started = 1; print }
    END { if (!found) exit 2 }
  ' "${CHANGELOG}"
  )"; then
  echo "error: no changelog section found for ${VERSION} in ${CHANGELOG}" >&2
  exit 1
fi

if [[ -z "${NOTES}" ]]; then
  echo "error: no human-readable notes found for ${VERSION} in ${CHANGELOG}" >&2
  exit 1
fi

printf '%s\n' "${NOTES}"

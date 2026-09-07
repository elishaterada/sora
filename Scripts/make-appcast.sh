#!/usr/bin/env bash
# Sign a packaged Sora update and create the single-item Sparkle feed published
# alongside it on GitHub Releases.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MARKETING_VERSION="${MARKETING_VERSION:?MARKETING_VERSION is required}"
CURRENT_PROJECT_VERSION="${CURRENT_PROJECT_VERSION:?CURRENT_PROJECT_VERSION is required}"
RELEASE_TAG="${RELEASE_TAG:?RELEASE_TAG is required}"
SPARKLE_ED_PRIVATE_KEY="${SPARKLE_ED_PRIVATE_KEY:?SPARKLE_ED_PRIVATE_KEY is required}"
ZIP="${1:?path to the packaged update zip is required}"
SIGN_UPDATE="${SPARKLE_SIGN_UPDATE:-${ROOT}/.derivedData-package/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update}"
APPCAST="${ROOT}/dist/appcast.xml"

if [[ ! -f "${ZIP}" ]]; then
  echo "error: update archive missing at ${ZIP}" >&2
  exit 1
fi
if [[ ! -x "${SIGN_UPDATE}" ]]; then
  echo "error: Sparkle sign_update missing at ${SIGN_UPDATE}" >&2
  exit 1
fi
if [[ ! "${CURRENT_PROJECT_VERSION}" =~ ^[0-9]+$ ]]; then
  echo "error: build version must be numeric" >&2
  exit 1
fi
if [[ ! "${RELEASE_TAG}" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "error: release tag contains unsupported characters" >&2
  exit 1
fi

SIGNATURE_ATTRIBUTES="$(printf '%s' "${SPARKLE_ED_PRIVATE_KEY}" | "${SIGN_UPDATE}" --ed-key-file - "${ZIP}")"
ARCHIVE_NAME="$(basename "${ZIP}")"
DOWNLOAD_BASE_URL="${SPARKLE_DOWNLOAD_BASE_URL:-https://github.com/elishaterada/sora/releases/download/${RELEASE_TAG}}"
DOWNLOAD_URL="${DOWNLOAD_BASE_URL}/${ARCHIVE_NAME}"
RELEASE_URL="https://github.com/elishaterada/sora/releases/tag/${RELEASE_TAG}"
PUB_DATE="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S %z')"
RELEASE_NOTES="$("${ROOT}/Scripts/extract-release-notes.sh" "${MARKETING_VERSION}" "${ROOT}/CHANGELOG.md")"

if [[ "${RELEASE_NOTES}" == *"]]>"* ]]; then
  echo "error: release notes cannot contain the XML CDATA terminator ]]>" >&2
  exit 1
fi

cat > "${APPCAST}" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
  <channel>
    <title>Sora Updates</title>
    <link>https://github.com/elishaterada/sora/releases</link>
    <description>Stable Sora updates</description>
    <language>en</language>
    <item>
      <title>Sora ${MARKETING_VERSION}</title>
      <link>${RELEASE_URL}</link>
      <pubDate>${PUB_DATE}</pubDate>
      <sparkle:version>${CURRENT_PROJECT_VERSION}</sparkle:version>
      <sparkle:shortVersionString>${MARKETING_VERSION}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
      <description sparkle:format="markdown"><![CDATA[${RELEASE_NOTES}]]></description>
      <enclosure url="${DOWNLOAD_URL}" ${SIGNATURE_ATTRIBUTES} type="application/octet-stream" />
    </item>
  </channel>
</rss>
EOF

printf '%s' "${SPARKLE_ED_PRIVATE_KEY}" | "${SIGN_UPDATE}" --ed-key-file - "${APPCAST}"
echo "Created signed Sparkle feed at ${APPCAST}"

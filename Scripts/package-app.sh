#!/usr/bin/env bash
# Build a Release Sora.app zip for sharing (ad-hoc signed, not notarized).
#
# Usage:
#   ./Scripts/package-app.sh
#   MARKETING_VERSION=0.1.0 CURRENT_PROJECT_VERSION=42 ./Scripts/package-app.sh
#
# Env:
#   MARKETING_VERSION          CFBundleShortVersionString (default: 0.1.0)
#   CURRENT_PROJECT_VERSION    CFBundleVersion / build (default: 1)
#   SKIP_GHOSTTY_BUILD=1       Assume Vendor/ghostty products already exist
#   CONFIGURATION              Xcode config (default: Release)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT}"

MARKETING_VERSION="${MARKETING_VERSION:-0.1.0}"
CURRENT_PROJECT_VERSION="${CURRENT_PROJECT_VERSION:-1}"
CONFIGURATION="${CONFIGURATION:-Release}"
ARCH="$(uname -m)"
case "${ARCH}" in
  arm64) ARCH_LABEL="arm64" ;;
  x86_64) ARCH_LABEL="x86_64" ;;
  *) ARCH_LABEL="${ARCH}" ;;
esac

if [[ "${SKIP_GHOSTTY_BUILD:-0}" != "1" ]]; then
  ./Scripts/build-ghosttykit.sh
fi

DERIVED="${ROOT}/.derivedData-package"
rm -rf "${DERIVED}"
mkdir -p "${ROOT}/dist"

echo "Building Sora ${MARKETING_VERSION} (${CURRENT_PROJECT_VERSION}) ${CONFIGURATION} (${ARCH_LABEL})…"
xcodebuild \
  -project "${ROOT}/Sora.xcodeproj" \
  -scheme Sora \
  -configuration "${CONFIGURATION}" \
  -destination "platform=macOS,arch=${ARCH}" \
  -derivedDataPath "${DERIVED}" \
  ARCHS="${ARCH}" \
  ONLY_ACTIVE_ARCH=YES \
  MARKETING_VERSION="${MARKETING_VERSION}" \
  CURRENT_PROJECT_VERSION="${CURRENT_PROJECT_VERSION}" \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=YES \
  build

APP="${DERIVED}/Build/Products/${CONFIGURATION}/Sora.app"
if [[ ! -d "${APP}" ]]; then
  echo "error: expected app missing at ${APP}" >&2
  exit 1
fi

STAGE_NAME="Sora-${MARKETING_VERSION}-${CURRENT_PROJECT_VERSION}-macos-${ARCH_LABEL}"
STAGE="${ROOT}/dist/${STAGE_NAME}"
rm -rf "${STAGE}"
mkdir -p "${STAGE}"
ditto "${APP}" "${STAGE}/Sora.app"

cat > "${STAGE}/INSTALL.txt" <<EOF
Sora ${MARKETING_VERSION} (build ${CURRENT_PROJECT_VERSION}) — macOS ${ARCH_LABEL}

This build is ad-hoc signed and not notarized. Gatekeeper will warn on first open.

Install:
  1. Unzip this archive.
  2. Move Sora.app somewhere permanent (e.g. /Applications or ~/Applications).
  3. First launch — either:
       • Right-click Sora.app → Open → Open
       • Or clear quarantine:  xattr -cr /path/to/Sora.app
          then open normally.

Requirements: macOS 13+, Apple Silicon preferred for CI artifacts.

Working name; not a public release. Feedback welcome.
EOF

cp "${ROOT}/docs/licensing.md" "${STAGE}/LICENSING.md"
if [[ -f "${ROOT}/ThirdPartyNotices.txt" ]]; then
  cp "${ROOT}/ThirdPartyNotices.txt" "${STAGE}/ThirdPartyNotices.txt"
fi

ZIP="${ROOT}/dist/${STAGE_NAME}.zip"
rm -f "${ZIP}"
# --norsrc/--noextattr avoid AppleDouble "._" junk in the archive.
ditto -c -k --keepParent --norsrc --noextattr "${STAGE}" "${ZIP}"

# Drop the unzipped stage; keep the zip.
rm -rf "${STAGE}"

echo "Packaged ${ZIP}"
ls -lh "${ZIP}"

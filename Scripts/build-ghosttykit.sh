#!/usr/bin/env bash
# Build GhosttyKit.xcframework and terminfo for the Sora Xcode project.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GHOSTTY_DIR="${ROOT}/Vendor/ghostty"
GHOSTTY_COMMIT="c81f0b26871c7fbbe2fc35549fdad1f64ed29094"
GHOSTTY_REMOTE="https://github.com/ghostty-org/ghostty.git"

if ! command -v zig >/dev/null; then
  echo "error: zig 0.16.0 is required. Install with: brew install zig" >&2
  exit 1
fi

ZIG_VERSION="$(zig version)"
case "${ZIG_VERSION}" in
  0.16.*) ;;
  *)
    echo "error: Ghostty main at ${GHOSTTY_COMMIT} needs Zig 0.16.x, found ${ZIG_VERSION}" >&2
    exit 1
    ;;
esac

if [[ ! -d "${GHOSTTY_DIR}/.git" ]]; then
  mkdir -p "$(dirname "${GHOSTTY_DIR}")"
  git clone --filter=blob:none "${GHOSTTY_REMOTE}" "${GHOSTTY_DIR}"
fi

git -C "${GHOSTTY_DIR}" fetch --depth 1 origin "${GHOSTTY_COMMIT}"
git -C "${GHOSTTY_DIR}" checkout --detach "${GHOSTTY_COMMIT}"

if ! xcrun -sdk macosx metal --version >/dev/null 2>&1; then
  echo "Metal Toolchain missing; downloading..."
  xcodebuild -downloadComponent MetalToolchain
fi

cd "${GHOSTTY_DIR}"
zig build \
  -Demit-xcframework=true \
  -Dxcframework-target=native \
  -Demit-macos-app=false \
  -Doptimize=ReleaseFast

if [[ ! -d "${GHOSTTY_DIR}/macos/GhosttyKit.xcframework" ]]; then
  echo "error: GhosttyKit.xcframework was not produced" >&2
  exit 1
fi

if [[ ! -e "${GHOSTTY_DIR}/zig-out/share/terminfo/78/xterm-ghostty" ]]; then
  echo "error: terminfo xterm-ghostty was not produced" >&2
  exit 1
fi

echo "GhosttyKit ready at ${GHOSTTY_DIR}/macos/GhosttyKit.xcframework"
echo "terminfo ready at ${GHOSTTY_DIR}/zig-out/share/terminfo"

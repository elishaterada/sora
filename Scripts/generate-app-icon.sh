#!/usr/bin/env bash
# Regenerate Sora/Resources/Assets.xcassets/AppIcon.appiconset from app-icon.png.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/app-icon.png"
DEST="$ROOT/Sora/Resources/Assets.xcassets/AppIcon.appiconset"

if [[ ! -f "$SRC" ]]; then
  echo "missing source icon: $SRC" >&2
  exit 1
fi

mkdir -p "$DEST"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

declare -a SPECS=(
  "16:icon_16x16@1x.png"
  "32:icon_16x16@2x.png"
  "32:icon_32x32@1x.png"
  "64:icon_32x32@2x.png"
  "128:icon_128x128@1x.png"
  "256:icon_128x128@2x.png"
  "256:icon_256x256@1x.png"
  "512:icon_256x256@2x.png"
  "512:icon_512x512@1x.png"
  "1024:icon_512x512@2x.png"
)

for spec in "${SPECS[@]}"; do
  size="${spec%%:*}"
  name="${spec##*:}"
  sips -z "$size" "$size" "$SRC" --out "$WORKDIR/$name" >/dev/null
  cp "$WORKDIR/$name" "$DEST/$name"
done

cat > "$DEST/Contents.json" <<'EOF'
{
  "images" : [
    { "filename" : "icon_16x16@1x.png", "idiom" : "mac", "scale" : "1x", "size" : "16x16" },
    { "filename" : "icon_16x16@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "16x16" },
    { "filename" : "icon_32x32@1x.png", "idiom" : "mac", "scale" : "1x", "size" : "32x32" },
    { "filename" : "icon_32x32@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "32x32" },
    { "filename" : "icon_128x128@1x.png", "idiom" : "mac", "scale" : "1x", "size" : "128x128" },
    { "filename" : "icon_128x128@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "128x128" },
    { "filename" : "icon_256x256@1x.png", "idiom" : "mac", "scale" : "1x", "size" : "256x256" },
    { "filename" : "icon_256x256@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "256x256" },
    { "filename" : "icon_512x512@1x.png", "idiom" : "mac", "scale" : "1x", "size" : "512x512" },
    { "filename" : "icon_512x512@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "512x512" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
EOF

echo "AppIcon regenerated from app-icon.png"

#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

SRC="${1:-$ROOT_DIR/Assets/app-icon-source.png}"

if [[ ! -f "$SRC" ]]; then
  echo "Missing source image: $SRC" >&2
  echo "Place your 1024x1024 PNG there (or pass a path as arg 1)." >&2
  exit 1
fi

OUT_MASTER="$ROOT_DIR/Assets/app-icon.png"
ICONSET_DIR="$ROOT_DIR/Assets/AppIcon.iconset"
OUT_ICNS="$ROOT_DIR/Assets/AppIcon.icns"

TMP_MASTER="$(mktemp -t appicon_1024).png"
trap 'rm -f "$TMP_MASTER"' EXIT

ARGS=(--input "$SRC" --output "$TMP_MASTER")
if [[ -n "${THRESHOLD:-}" ]]; then
  ARGS+=(--threshold "$THRESHOLD")
fi
if [[ -n "${BATTERY_ALPHA:-}" ]]; then
  ARGS+=(--battery-alpha "$BATTERY_ALPHA")
fi
if [[ -n "${BATTERY_IMAGE:-}" ]]; then
  ARGS+=(--battery-image "$BATTERY_IMAGE")
fi
if [[ -n "${BATTERY_THRESHOLD:-}" ]]; then
  ARGS+=(--battery-threshold "$BATTERY_THRESHOLD")
fi

swift "$ROOT_DIR/scripts/render_app_icon.swift" "${ARGS[@]}"

rm -rf "$ICONSET_DIR"
mkdir -p "$ICONSET_DIR"

make_png() {
  local size="$1"
  local name="$2"
  /usr/bin/sips -s format png "$TMP_MASTER" -z "$size" "$size" --out "$ICONSET_DIR/$name" >/dev/null
}

make_png 16  icon_16x16.png
make_png 32  icon_16x16@2x.png
make_png 32  icon_32x32.png
make_png 64  icon_32x32@2x.png
make_png 128 icon_128x128.png
make_png 256 icon_128x128@2x.png
make_png 256 icon_256x256.png
make_png 512 icon_256x256@2x.png
make_png 512 icon_512x512.png
cp "$TMP_MASTER" "$ICONSET_DIR/icon_512x512@2x.png"

cp "$TMP_MASTER" "$OUT_MASTER"
/usr/bin/iconutil -c icns "$ICONSET_DIR" -o "$OUT_ICNS"

xattr -c "$OUT_MASTER" "$OUT_ICNS" 2>/dev/null || true
echo "Wrote:"
echo "  $OUT_MASTER"
echo "  $ICONSET_DIR"
echo "  $OUT_ICNS"

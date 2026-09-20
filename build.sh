#!/bin/sh
set -eu
ROOT="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "$ROOT/config.sh"
load_identity
resolve_codesign_identity
cd "$ROOT"

ICON_SRC="${ICON_SRC:-icons/option-b4-white-cursor-big.png}"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$ROOT/bin"

subst_plist() {
  python3 - "$1" "$2" <<'PY'
import os, sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src, encoding="utf-8").read()
for key in (
    "BUNDLE_ID",
    "MCP_BUNDLE_ID",
    "APP_DISPLAY_NAME",
    "EXEC",
    "SERVER_EXEC",
    "LAUNCHD_LABEL",
    "SUPPORT_DIR",
):
    text = text.replace("__%s__" % key, os.environ[key])
open(dst, "w", encoding="utf-8").write(text)
PY
}

export BUNDLE_ID MCP_BUNDLE_ID APP_DISPLAY_NAME EXEC SERVER_EXEC LAUNCHD_LABEL SUPPORT_DIR
subst_plist "$ROOT/Info.plist.in" "$APP/Contents/Info.plist"
MCP_PLIST="$(mktemp)"
subst_plist "$ROOT/mcp_server-Info.plist.in" "$MCP_PLIST"

if [ ! -f "$ICON_SRC" ]; then
  echo "missing icon $ICON_SRC" >&2
  exit 1
fi
ICON_PNG="$(mktemp).png"
sips -s format png "$ICON_SRC" --out "$ICON_PNG" >/dev/null
python3 icons/apply_squircle.py "$ICON_PNG" "$ICON_PNG"
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
sips -z 16 16     "$ICON_PNG" --out "$ICONSET/icon_16x16.png" >/dev/null
sips -z 32 32     "$ICON_PNG" --out "$ICONSET/icon_16x16@2x.png" >/dev/null
sips -z 32 32     "$ICON_PNG" --out "$ICONSET/icon_32x32.png" >/dev/null
sips -z 64 64     "$ICON_PNG" --out "$ICONSET/icon_32x32@2x.png" >/dev/null
sips -z 128 128   "$ICON_PNG" --out "$ICONSET/icon_128x128.png" >/dev/null
sips -z 256 256   "$ICON_PNG" --out "$ICONSET/icon_128x128@2x.png" >/dev/null
sips -z 256 256   "$ICON_PNG" --out "$ICONSET/icon_256x256.png" >/dev/null
sips -z 512 512   "$ICON_PNG" --out "$ICONSET/icon_256x256@2x.png" >/dev/null
sips -z 512 512   "$ICON_PNG" --out "$ICONSET/icon_512x512.png" >/dev/null
sips -z 1024 1024 "$ICON_PNG" --out "$ICONSET/icon_512x512@2x.png" >/dev/null
iconutil -c icns -o "$APP/Contents/Resources/AppIcon.icns" "$ICONSET"
rm -rf "$(dirname "$ICONSET")" "$ICON_PNG"

swiftc -O -o "$HELPER" helper.swift -framework ScreenCaptureKit
swiftc -O \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$MCP_PLIST" \
  -o "$SERVER_BIN" mcp_server.swift
rm -f "$MCP_PLIST"

# Stable identity: ad-hoc (-s -) changes cdhash every build and drops Accessibility.
codesign --force --options runtime --sign "${CODESIGN_IDENTITY}" --identifier "${MCP_BUNDLE_ID}" --timestamp "$SERVER_BIN"
codesign --force --options runtime --sign "${CODESIGN_IDENTITY}" --identifier "${BUNDLE_ID}" --timestamp "${APP}"
ln -sfn "../${APP_BUNDLE}/Contents/MacOS/${EXEC}" "$ROOT/bin/helper"

echo "built ${APP_BUNDLE} signed as ${CODESIGN_IDENTITY}"
echo "bundle ${BUNDLE_ID}"
echo "icon ${ICON_SRC}"

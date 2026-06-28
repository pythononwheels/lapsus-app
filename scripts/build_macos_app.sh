#!/usr/bin/env bash
# Build a double-clickable macOS LAPSUS.app from the Elixir release.
# The .app bundles ERTS — no Elixir/mix on the user's machine.
#
#   scripts/build_macos_app.sh        # build release + assemble dist/LAPSUS.app
#   REUSE_RELEASE=1 scripts/...       # skip the release build, reuse _build
#
# Note: unsigned — for distribution it needs codesign + notarization (Gatekeeper).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

REL_DIR="_build/prod/rel/lapsus"
APP="dist/LAPSUS.app"

if [ "${REUSE_RELEASE:-0}" != "1" ]; then
  echo "==> building release (MIX_ENV=prod mix release lapsus)"
  MIX_ENV=prod mix release lapsus --overwrite >/dev/null
fi

[ -d "$REL_DIR" ] || { echo "release not found at $REL_DIR"; exit 1; }

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp -R "$REL_DIR" "$APP/Contents/Resources/rel"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>LAPSUS</string>
  <key>CFBundleDisplayName</key><string>LAPSUS</string>
  <key>CFBundleIdentifier</key><string>ai.lapsus.app</string>
  <key>CFBundleVersion</key><string>0.1.0</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleExecutable</key><string>LAPSUS</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
  <key>NSLocalNetworkUsageDescription</key><string>LAPSUS connects directly to other peers to send and receive AI requests, peer to peer.</string>
</dict></plist>
PLIST

cat > "$APP/Contents/MacOS/LAPSUS" <<'LAUNCH'
#!/usr/bin/env bash
# Double-click entry point: boot the provider app (opens the browser itself).
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
export LAPSUS_RUN=1
exec "$HERE/../Resources/rel/bin/lapsus" start
LAUNCH
chmod +x "$APP/Contents/MacOS/LAPSUS"

# --- app icon: build AppIcon.icns from the logo (square, white bg, centered) ---
ICON_SRC="apps/lapsus_agent/priv/static/lapsus.png"
if [ -f "$ICON_SRC" ] && command -v iconutil >/dev/null 2>&1; then
  echo "==> building app icon"
  WORK="$(mktemp -d)"
  ISET="$WORK/AppIcon.iconset"
  mkdir -p "$ISET"
  # scale logo to fit, then pad to a 1024 square on white (matches the b/w look)
  sips -Z 880 "$ICON_SRC" --out "$WORK/scaled.png" >/dev/null
  sips --padToHeightWidth 1024 1024 --padColor FFFFFF "$WORK/scaled.png" --out "$WORK/master.png" >/dev/null
  gen() { sips -z "$1" "$1" "$WORK/master.png" --out "$ISET/$2" >/dev/null; }
  gen 16   icon_16x16.png
  gen 32   icon_16x16@2x.png
  gen 32   icon_32x32.png
  gen 64   icon_32x32@2x.png
  gen 128  icon_128x128.png
  gen 256  icon_128x128@2x.png
  gen 256  icon_256x256.png
  gen 512  icon_256x256@2x.png
  gen 512  icon_512x512.png
  gen 1024 icon_512x512@2x.png
  iconutil -c icns "$ISET" -o "$APP/Contents/Resources/AppIcon.icns"
  rm -rf "$WORK"
else
  echo "==> (skipping icon — iconutil or logo missing)"
fi

# --- ad-hoc code signing ---
# Unsigned bundles make macOS attribute network access (and the Local Network
# prompt) to the bare "beam.smp" binary. An ad-hoc signature ties the nested
# binaries to the bundle, so macOS shows "LAPSUS" + our usage description. (It is
# NOT a trusted signature — Gatekeeper still needs notarization or the curl path.)
if command -v codesign >/dev/null 2>&1; then
  echo "==> ad-hoc signing the bundle"
  codesign --force --deep --sign - "$APP" >/dev/null 2>&1 \
    && echo "    signed (ad-hoc)" \
    || echo "    (codesign failed — shipping unsigned)"
fi

echo "==> done: $APP"
echo "    Double-click it in Finder, or: open '$APP'"

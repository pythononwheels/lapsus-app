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
  <key>LSMinimumSystemVersion</key><string>12.0</string>
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

echo "==> done: $APP"
echo "    Double-click it in Finder, or: open '$APP'"

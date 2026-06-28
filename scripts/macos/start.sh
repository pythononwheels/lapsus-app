#!/bin/bash
# Start LAPSUS on macOS (unsigned beta).
#
# Run this from Terminal — NOT by double-clicking:
#
#     cd <this folder>
#     bash start.sh
#
# Why Terminal: macOS flags anything downloaded via a browser with a "quarantine"
# attribute, and for an unsigned app a Finder double-click turns that into a hard
# "unidentified developer" block. A shell script run with `bash start.sh` is
# interpreted by bash (not launched through Gatekeeper), so it runs — it strips
# the quarantine flag from the app and then opens it. After this, LAPSUS.app
# launches normally on a plain double-click.
#
# (Even simpler, with no download quarantine at all:
#     curl -fsSL https://lapsus.pyrates.io/install.sh | bash )

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ ! -d "$DIR/LAPSUS.app" ]; then
  echo "LAPSUS.app not found next to start.sh — keep them in the same folder."
  exit 1
fi

echo "Clearing the macOS download quarantine ..."
xattr -dr com.apple.quarantine "$DIR" 2>/dev/null

echo "Launching LAPSUS ..."
if open "$DIR/LAPSUS.app"; then
  echo "Done — LAPSUS is opening. You can close this window."
else
  echo "Couldn't launch automatically. Try double-clicking LAPSUS.app now."
fi

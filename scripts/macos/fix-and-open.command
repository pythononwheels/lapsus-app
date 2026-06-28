#!/bin/sh
# Fix & Open LAPSUS — for the unsigned macOS beta.
#
# Double-click this once. macOS flags anything downloaded from the internet with a
# "quarantine" attribute; for an unsigned app that turns the first launch into a
# hard "unidentified developer" block. This script removes that flag from
# LAPSUS.app (which sits next to it) and opens the app. After this, LAPSUS opens
# normally on a plain double-click.
#
# (A script run from Finder only gets a soft "downloaded from the internet — open?"
# prompt, not the hard app block — that's why this works where the app alone can't.)

cd "$(dirname "$0")" || exit 1

APP="LAPSUS.app"
if [ ! -d "$APP" ]; then
  echo "Couldn't find $APP next to this script."
  echo "Keep 'Fix & Open LAPSUS.command' and LAPSUS.app in the same folder, then run it again."
  exit 1
fi

echo "Clearing the macOS download quarantine on $APP ..."
xattr -dr com.apple.quarantine "$APP" 2>/dev/null

echo "Launching LAPSUS ..."
if open "$APP"; then
  echo "Done — LAPSUS is opening. You can close this window."
else
  echo "Couldn't launch automatically. Try double-clicking LAPSUS.app now."
fi

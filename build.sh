#!/bin/bash
# Build, bundle, sign, install to /Applications, launch. Idempotent.
#
# No icon step: this is an LSUIElement accessory app with no Dock tile, so there
# is nothing to draw an icon on. It lives in the menubar.
set -e
cd "$(dirname "$0")"
APP="Dictation.app"

swiftc -O -target arm64-apple-macos26.0 -o dictation main.swift \
  -framework Cocoa -framework AVFoundation -framework Speech -framework ServiceManagement \
  -framework CoreAudio -framework AudioToolbox

rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp dictation "$APP/Contents/MacOS/Dictation"; chmod +x "$APP/Contents/MacOS/Dictation"
cp Info.plist "$APP/Contents/Info.plist"

# OPTIONAL start/stop cue sounds. None ship in this repo: pick or make your own.
# Drop custom_start.wav and custom_stop.wav in sounds/ and they get bundled.
#
# Worth knowing if you make your own: a dictation cue wants to be UNDER ~150ms or
# it reads as a notification rather than as a button. Most stock system sounds are
# 400 to 600ms and feel wrong here. A weak, slow attack is what reads as "soft";
# a bright transient on the front reads as an alert no matter how quiet it is.
for w in custom_start custom_stop; do
  [ -f "sounds/$w.wav" ] && cp "sounds/$w.wav" "$APP/Contents/Resources/"
done

cp glossary.json "$APP/Contents/Resources/"

# STABLE SIGNING, deliberately not adhoc. TCC matches an adhoc-signed app by its
# cdhash, so every rebuild changes the hash and SILENTLY revokes Accessibility.
# Signing with a real identity keeps the grant across rebuilds. Falls back to adhoc
# on a machine without the cert rather than failing the build.
IDENTITY=$(security find-identity -v 2>/dev/null | grep -o '"Apple Development:[^"]*"' | head -1 | tr -d '"')
if [ -n "$IDENTITY" ]; then
  echo "signing with: $IDENTITY"
  codesign --force --deep --sign "$IDENTITY" "$APP"
else
  echo "WARNING: no stable identity found, falling back to adhoc (grant will not survive rebuilds)"
  codesign --force --deep --sign - "$APP"
fi

osascript -e 'quit app "Dictation"' 2>/dev/null || true; sleep 1
rm -rf "/Applications/$APP"; cp -R "$APP" /Applications/
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "/Applications/$APP"
open -a Dictation

echo "installed."
echo "Signed with a stable identity: Accessibility and Microphone grants SURVIVE rebuilds."
echo "If it says NOT GRANTED right after you grant it, relaunch: the app only checks at launch."

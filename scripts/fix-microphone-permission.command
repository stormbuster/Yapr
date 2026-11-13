#!/bin/zsh
# Makes macOS ask for Yapr's microphone permission again, on a Mac where Yapr does not appear under
# System Settings › Privacy & Security › Microphone (typically a Mac the app was copied to).
#
# macOS lists an app there only after a permission request it can attribute to a validly signed app. A copied,
# ad-hoc signed app can lose that: its quarantine flag, a signature that no longer verifies, or a stale entry.
# This script shows what it finds, then clears quarantine, re-signs the app on this Mac, resets Yapr's microphone
# entry and opens Yapr, which asks for the microphone straight away.
#
#   Double-click it, or run:  zsh fix-microphone-permission.command [/path/to/Yapr.app]
set -u

app=${1:-/Applications/Yapr.app}
bundle_id=com.stormbuster.yapr
[[ -d $app ]] || { echo "Yapr.app not found at $app. Move it to Applications first, or pass its path."; exit 1; }

echo "== Yapr microphone permission repair"
echo "macOS $(sw_vers -productVersion) on $(uname -m), app at $app"
echo
echo "-- Before"
xattr -p com.apple.quarantine "$app" >/dev/null 2>&1 && echo "quarantined: yes" || echo "quarantined: no"
if codesign --verify --deep --strict "$app" 2>/dev/null; then echo "signature: valid"; else echo "signature: INVALID ($(codesign --verify --deep --strict "$app" 2>&1 | tail -1))"; fi
case "$app" in */AppTranslocation/*) echo "running translocated: yes";; esac
/usr/libexec/PlistBuddy -c 'Print NSMicrophoneUsageDescription' "$app/Contents/Info.plist" >/dev/null 2>&1 \
    && echo "microphone usage text: present" || echo "microphone usage text: MISSING"

echo
echo "-- Repair"
osascript -e "tell application id \"$bundle_id\" to quit" >/dev/null 2>&1
pkill -x Yapr 2>/dev/null; sleep 1
xattr -dr com.apple.quarantine "$app" && echo "quarantine cleared"
# Same identity as the build: an ad-hoc signature whose designated requirement is the bundle id, so the permission
# survives later updates of the app.
req="designated => identifier \"$bundle_id\""
if codesign --force --deep --sign - -r="$req" --preserve-metadata=entitlements "$app" 2>/dev/null; then
    echo "re-signed on this Mac"
else
    echo "re-signing failed:"; codesign --force --deep --sign - -r="$req" --preserve-metadata=entitlements "$app"
fi
codesign --verify --deep --strict "$app" && echo "signature: valid"
tccutil reset Microphone "$bundle_id" >/dev/null 2>&1 && echo "microphone entry reset"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$app"

echo
echo "-- Opening Yapr: in the window it shows, press Allow, then allow the microphone when macOS asks"
start=$(date '+%Y-%m-%d %H:%M:%S')
open "$app"
echo "(waiting 30 s for you to answer)"
sleep 30
echo
echo "-- What macOS's privacy service recorded (paste this if it still fails)"
log show --style compact --start "$start" --predicate 'process == "tccd"' 2>/dev/null \
    | grep -E "kTCCServiceMicrophone|kTCCServiceAudioCapture|Policy disallows|AUTHREQ_ATTRIBUTION.*$bundle_id|AUTHREQ_RESULT|prompt" \
    | cut -c1-260 | tail -25
echo
echo "Done. Yapr should now be listed under System Settings › Privacy & Security › Microphone."

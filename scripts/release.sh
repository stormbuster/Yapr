#!/bin/zsh
# Builds Yapr in Release and installs it, replacing any earlier copy, then launches it.
#
#   scripts/release.sh                 # installs to /Applications
#   scripts/release.sh ~/Applications  # or another folder
#   scripts/release.sh --no-launch     # install without starting it
set -euo pipefail

cd "${0:A:h}/.."

dest=/Applications
launch=1
for arg in "$@"; do
    case $arg in
        --no-launch) launch=0 ;;
        -h|--help) sed -n '2,7p' "$0"; exit 0 ;;
        *) dest=${arg%/} ;;
    esac
done

[[ -d $dest ]] || { echo "No such folder: $dest" >&2; exit 1; }
[[ -w $dest ]] || { echo "Cannot write to $dest" >&2; exit 1; }
command -v xcodegen >/dev/null || { echo "XcodeGen is required: brew install xcodegen" >&2; exit 1; }

echo "› Generating project"
xcodegen generate --quiet

echo "› Building Release"
log=build/release.log
mkdir -p build
if ! xcodebuild -project Yapr.xcodeproj -scheme Yapr -configuration Release \
        -derivedDataPath build -destination 'platform=macOS,arch=arm64' build >"$log" 2>&1; then
    grep -E "error:" "$log" >&2 || tail -30 "$log" >&2
    echo "Build failed; full log in $log" >&2
    exit 1
fi
app=build/Build/Products/Release/Yapr.app
codesign --verify --deep "$app"

if pgrep -xq Yapr; then
    echo "› Quitting the running Yapr"
    osascript -e 'tell application id "com.stormbuster.yapr" to quit' >/dev/null 2>&1 || true
    for _ in {1..20}; do pgrep -xq Yapr || break; sleep 0.25; done
    pkill -x Yapr 2>/dev/null || true
fi

echo "› Installing to $dest/Yapr.app"
rm -rf "$dest/Yapr.app"
ditto "$app" "$dest/Yapr.app"

version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$dest/Yapr.app/Contents/Info.plist")
echo "✓ Yapr $version installed ($(git rev-parse --short HEAD)$(git diff --quiet HEAD -- . ':!build' || echo ', with uncommitted changes'))"

if (( launch )); then
    open "$dest/Yapr.app"
    echo "✓ Launched"
fi

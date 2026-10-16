#!/bin/zsh
# Builds Yapr in Release as a universal app (Apple silicon and Intel), installs it, replacing any earlier copy,
# then launches it.
#
#   scripts/release.sh                 # installs to /Applications
#   scripts/release.sh ~/Applications  # or another folder
#   scripts/release.sh --no-launch     # install without starting it
#   scripts/release.sh --zip           # also write build/Yapr-<version>.zip, e.g. to copy to another Mac
set -euo pipefail

cd "${0:A:h}/.."

dest=/Applications
launch=1
zip=0
for arg in "$@"; do
    case $arg in
        --no-launch) launch=0 ;;
        --zip) zip=1 ;;
        -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
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
        -derivedDataPath build -destination 'generic/platform=macOS' build >"$log" 2>&1; then
    grep -E "error:" "$log" >&2 || tail -30 "$log" >&2
    echo "Build failed; full log in $log" >&2
    exit 1
fi
app=build/Build/Products/Release/Yapr.app
codesign --verify --deep "$app"
archs=$(lipo -archs "$app/Contents/MacOS/Yapr")
[[ $archs == *x86_64* && $archs == *arm64* ]] || { echo "Expected a universal binary, got: $archs" >&2; exit 1; }

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
echo "✓ Yapr $version ($archs) installed ($(git rev-parse --short HEAD)$(git diff --quiet HEAD -- . ':!build' || echo ', with uncommitted changes'))"

if (( zip )); then
    archive="build/Yapr-$version.zip"
    rm -f "$archive"
    ditto -c -k --keepParent "$app" "$archive"
    echo "✓ $archive ($(du -h "$archive" | cut -f1))"
fi

if (( launch )); then
    open "$dest/Yapr.app"
    echo "✓ Launched"
fi

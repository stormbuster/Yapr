#!/bin/zsh
# Builds Yapr in Release as a universal app (Apple silicon and Intel), installs it, replacing any earlier copy,
# then launches it.
#
#   scripts/release.sh                 # installs to /Applications
#   scripts/release.sh ~/Applications  # or another folder
#   scripts/release.sh --no-launch     # install without starting it
#   scripts/release.sh --zip           # also write build/Yapr-<version>-<commit>.zip, e.g. to copy to another Mac
#   scripts/release.sh --zip --no-install   # only build the zip; leave this Mac's copy alone
set -euo pipefail

cd "${0:A:h}/.."

dest=/Applications
launch=1
zip=0
install=1
for arg in "$@"; do
    case $arg in
        --no-launch) launch=0 ;;
        --zip) zip=1 ;;
        --no-install) install=0; launch=0 ;;
        -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
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

version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Contents/Info.plist")

if (( install )); then
if pgrep -xq Yapr; then
    echo "› Quitting the running Yapr"
    osascript -e 'tell application id "com.stormbuster.yapr" to quit' >/dev/null 2>&1 || true
    for _ in {1..20}; do pgrep -xq Yapr || break; sleep 0.25; done
    pkill -x Yapr 2>/dev/null || true
fi

echo "› Installing to $dest/Yapr.app"
rm -rf "$dest/Yapr.app"
ditto "$app" "$dest/Yapr.app"

echo "✓ Yapr $version ($archs) installed ($(git rev-parse --short HEAD)$(git diff --quiet HEAD -- . ':!build' || echo ', with uncommitted changes'))"
fi

if (( zip )); then
    # A folder with the app and the permission repair script, for copying to another Mac.
    name="Yapr-$version-$(git rev-parse --short HEAD)"
    stage="build/$name"
    rm -rf "$stage" "build/$name.zip"
    mkdir -p "$stage"
    ditto "$app" "$stage/Yapr.app"
    cp scripts/fix-microphone-permission.command "$stage/"
    cat > "$stage/Read me.txt" <<'TXT'
Yapr for Apple silicon and Intel Macs (macOS 15 or later)

1. Move Yapr.app into Applications.
2. Open it. If macOS refuses because it is from an unidentified developer, open System Settings ›
   Privacy & Security and click Open Anyway (or Control-click Yapr and choose Open).
3. Allow the microphone when asked. On first launch Yapr also downloads its speech model (330 MB)
   and prepares it, which takes a minute or two once.

If Yapr does not ask for the microphone, or does not appear under System Settings › Privacy & Security ›
Microphone: open Terminal and run
    zsh ~/Downloads/<this folder>/fix-microphone-permission.command
(drag the file onto the Terminal window to fill in its path). It repairs the app's signature and
permission entry on this Mac and opens Yapr so macOS asks again.
TXT
    ditto -c -k --keepParent "$stage" "build/$name.zip"
    echo "✓ build/$name.zip ($(du -h "build/$name.zip" | cut -f1)): Yapr.app, fix-microphone-permission.command, Read me.txt"
fi

if (( launch )); then
    open "$dest/Yapr.app"
    echo "✓ Launched"
fi

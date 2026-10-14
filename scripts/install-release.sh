#!/bin/bash
# Builds Release for the iPad and the Mac, keeps their debug symbols (for crash reports, by build number),
# installs on the iPad if connected and into /Applications on this Mac.
set -euo pipefail
cd "$(dirname "$0")/.."
IPAD=00008103-0014312411E8A01E
SYMS="$HOME/Library/Developer/Scriptorium/dSYMs"
BUILD=$(sed -nE 's/^ *CURRENT_PROJECT_VERSION: "?([0-9]+)"?.*/\1/p' project.yml | head -1)
mkdir -p "$SYMS/$BUILD"

IOS_DD=/tmp/scriptorium-ios-release
xcodebuild -project Reader.xcodeproj -scheme Reader -configuration Release -destination "generic/platform=iOS" \
  -derivedDataPath "$IOS_DD" -allowProvisioningUpdates build -quiet
cp -R "$IOS_DD/Build/Products/Release-iphoneos/"*.dSYM "$SYMS/$BUILD/" 2>/dev/null || true
# Capture first: with pipefail, `grep -q` closing the pipe early made a connected iPad look absent.
DEVICES=$(xcrun devicectl list devices 2>/dev/null || true)
if grep -q "$IPAD.*\(available\|connected\)" <<< "$DEVICES"; then
  xcrun devicectl device install app --device "$IPAD" "$IOS_DD/Build/Products/Release-iphoneos/Reader.app" >/dev/null && echo "iPad: installed build $BUILD"
else
  echo "iPad: not connected, skipped"
fi

MAC_DD=/tmp/scriptorium-mac-release
xcodebuild -project Reader.xcodeproj -scheme ScriptoriumMac -configuration Release -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$MAC_DD" -allowProvisioningUpdates build -quiet
cp -R "$MAC_DD/Build/Products/Release/"*.dSYM "$SYMS/$BUILD/" 2>/dev/null || true
osascript -e 'tell application id "com.romadinov.reader.mac" to quit' 2>/dev/null || true
sleep 2
ditto "$MAC_DD/Build/Products/Release/Scriptorium.app" /Applications/Scriptorium.app
open /Applications/Scriptorium.app
echo "Mac: installed build $BUILD; symbols in $SYMS/$BUILD"

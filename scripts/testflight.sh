#!/bin/bash
# Archives the iPad/iPhone app and the Mac app (Release) and uploads both to App Store Connect for
# TestFlight, using the API key in ~/.appstoreconnect (see scripts/asc.swift). Keeps dSYMs per build.
# The key must have the Admin role: Xcode signs App Store builds with Apple's cloud-managed
# distribution certificate, which lower roles may not use ("Cloud signing permission error").
# Xcode's own upload step ignores the API key ("No Accounts with App Store Connect Access"), so the
# archive is signed and exported locally and the package is uploaded with altool and the same key.
# Usage: scripts/testflight.sh [ios|mac]   (default: both). Run scripts/bump-build.sh first.
set -euo pipefail
cd "$(dirname "$0")/.."
source "$HOME/.appstoreconnect/scriptorium.env"
KEY="$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8"
AUTH=(-allowProvisioningUpdates -authenticationKeyPath "$KEY" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
BUILD=$(sed -nE 's/^ *CURRENT_PROJECT_VERSION: "?([0-9]+)"?.*/\1/p' project.yml | head -1)
OUT=/tmp/scriptorium-testflight/$BUILD
SYMS="$HOME/Library/Developer/Scriptorium/dSYMs/$BUILD"
mkdir -p "$OUT" "$SYMS"
cat > "$OUT/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>export</string>
  <key>teamID</key><string>SZVSSCJQFN</string>
  <key>signingStyle</key><string>automatic</string>
  <key>uploadSymbols</key><true/>
  <key>manageAppVersionAndBuildNumber</key><false/>
</dict></plist>
PLIST

upload() {   # scheme, destination, name, altool platform
  echo "== $3: archiving build $BUILD"
  xcodebuild archive -project Reader.xcodeproj -scheme "$1" -configuration Release -destination "$2" \
    -archivePath "$OUT/$3.xcarchive" "${AUTH[@]}" -quiet
  cp -R "$OUT/$3.xcarchive/dSYMs/"*.dSYM "$SYMS/" 2>/dev/null || true
  echo "== $3: signing"
  rm -rf "$OUT/$3-export"
  xcodebuild -exportArchive -archivePath "$OUT/$3.xcarchive" -exportOptionsPlist "$OUT/ExportOptions.plist" \
    -exportPath "$OUT/$3-export" "${AUTH[@]}" -quiet
  echo "== $3: uploading"
  xcrun altool --upload-app -f "$(ls "$OUT/$3-export/"*.{ipa,pkg} 2>/dev/null | head -1)" -t "$4" \
    --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"
  echo "== $3: uploaded build $BUILD — it appears in TestFlight after Apple's processing (usually 10–30 min)"
}

WHICH=${1:-both}
[ "$WHICH" = mac ] || upload Reader "generic/platform=iOS" iOS ios
[ "$WHICH" = ios ] || upload ScriptoriumMac "generic/platform=macOS" Mac macos

#!/bin/bash
# Non-interactive look at the Mac app: builds it ad hoc, launches it in the background (no focus, no input
# synthesis), optionally opens a book, and captures each of its windows to PNGs. Then quits it.
# Usage: scripts/mac-snapshot.sh <output-dir> ["<path in library>"] [seconds to wait]
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=${1:?output dir}; BOOK=${2:-}; WAIT=${3:-6}
DD=/tmp/scriptorium-mac-dd
xcodebuild build -project Reader.xcodeproj -scheme ScriptoriumMac -destination 'platform=macOS' -derivedDataPath "$DD" \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER= \
  MAC_ENTITLEMENTS=ScriptoriumMac-Local -quiet
APP="$DD/Build/Products/Debug/Scriptorium.app"
pkill -x Scriptorium 2>/dev/null || true
SNAP="$HOME/Library/Containers/com.romadinov.reader.mac/Data/Documents/Snapshots"
rm -rf "$SNAP"
ARGS=(-ApplePersistenceIgnoreState YES -snapshotAfter "$WAIT")
[ -n "$BOOK" ] && ARGS+=(-openBook "$BOOK")
open -g -n -W "$APP" --args "${ARGS[@]}"
mkdir -p "$OUT"
cp "$SNAP"/*.png "$OUT"/ 2>/dev/null || true
ls "$OUT"

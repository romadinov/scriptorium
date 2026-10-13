#!/bin/bash
# Copies sample books into the Reader library on a booted simulator, in folders.
# Usage: scripts/seed-simulator.sh <device-id> <dir-with-books>
set -euo pipefail
DEVICE=${1:?device id}; SRC=${2:?folder with sample books}
DATA=$(xcrun simctl get_app_container "$DEVICE" com.romadinov.reader data)
LIB="$DATA/Documents/Books"
rm -rf "$LIB"; mkdir -p "$LIB/Physics" "$LIB/Fiction"
rm -f "$DATA/Documents/Read Later.md"            # tests add links and expect "Added", not "Already in"
cp "$SRC/Thermodynamics.pdf" "$SRC/Thermodynamics.djvu" "$LIB/Physics/"
[ -f "$SRC/Linked.pdf" ] && cp "$SRC/Linked.pdf" "$LIB/Physics/Linked.pdf"
cp "$SRC/Scanned.pdf" "$LIB/"
[ -f "$SRC/Entropy (Wikipedia).webarchive" ] && cp "$SRC/Entropy (Wikipedia).webarchive" "$LIB/"
[ -f "$SRC/Python 3.10 docs.chm" ] && cp "$SRC/Python 3.10 docs.chm" "$LIB/"
cp "$SRC/Pride.epub" "$LIB/Fiction/Pride and Prejudice.epub"
cp "$(dirname "$0")/../Packages/ReaderCore/Tests/ReaderCoreTests/Fixtures/sample.fb2" "$LIB/Fiction/Тепло и порядок.fb2"
if [ -f "$SRC/Heat and Order.doc" ]; then
  mkdir -p "$LIB/Word"
  cp "$SRC/Heat and Order.doc" "$LIB/Word/"
  [ -f "$SRC/Heat and Order (Word).docx" ] && cp "$SRC/Heat and Order (Word).docx" "$LIB/Word/"
  [ -f "$SRC/Hyphens.doc" ] && cp "$SRC/Hyphens.doc" "$LIB/Word/"
fi
[ -f "$SRC/azw/Pride.azw3" ] && cp "$SRC/azw/Pride.azw3" "$LIB/Fiction/Pride and Prejudice (Kindle).azw3"
# A reading position "from another device" (page 3 of the Thermodynamics PDF, saved in the future so it
# counts as newer). Positions/<fingerprint>/<device>.json; fingerprint as DocumentFingerprint.id.
python3 - "$LIB/Physics/Thermodynamics.pdf" "$DATA/Documents/Positions" <<'PY'
import hashlib, json, os, sys
path, root = sys.argv[1], sys.argv[2]
data = open(path, 'rb').read()
h = hashlib.sha256(str(len(data)).encode()); h.update(data[:256 * 1024])
if len(data) > 512 * 1024: h.update(data[-256 * 1024:])
folder = os.path.join(root, h.digest()[:10].hex()); os.makedirs(folder, exist_ok=True)
json.dump({"page": 2, "progress": 0, "label": "p. 3", "updated": "2030-01-01T00:00:00Z",
           "device": "Test Mac", "deviceID": "test-mac"}, open(os.path.join(folder, "test-mac.json"), "w"))
PY
# Device transfers (local fallback Documents/Devices without iCloud): this simulator is "sim-ipad", a
# "Test Mac" is registered, and a book "sent from the iPhone" waits in sim-ipad's transfer folder.
# (UI tests launch with -deviceID sim-ipad.)
DEV="$DATA/Documents/Devices"
rm -rf "$DEV"; mkdir -p "$DEV/Devices" "$DEV/Transfers/test-mac" "$DEV/Transfers/sim-ipad/Sent"
printf '{"id":"test-mac","name":"Test Mac","kind":"mac","lastSeen":"%s","folders":["Archive","Physics"]}' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$DEV/Devices/test-mac.json"
cp "$SRC/Scanned.pdf" "$DEV/Transfers/sim-ipad/Sent/Sent from iPhone.pdf"
# Without an iCloud account the app uses Documents/Inbox; leave two books there for the sync test.
INBOX="$DATA/Documents/Inbox"
rm -rf "$INBOX"; mkdir -p "$INBOX/Physics" "$INBOX/From Inbox"
cp "$SRC/Thermodynamics.pdf" "$INBOX/Physics/Thermodynamics (Inbox copy).pdf"
cp "$(dirname "$0")/../Packages/ReaderCore/Tests/ReaderCoreTests/Fixtures/sample3.epub" "$INBOX/From Inbox/Inbox Book.epub"
find "$LIB" "$INBOX" -type f | sed "s|$DATA/Documents/||"

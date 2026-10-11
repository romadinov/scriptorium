#!/bin/bash
# Copies sample books into the Reader library on a booted simulator, in folders.
# Usage: scripts/seed-simulator.sh <device-id> <dir-with-books>
set -euo pipefail
DEVICE=${1:?device id}; SRC=${2:?folder with sample books}
DATA=$(xcrun simctl get_app_container "$DEVICE" com.romadinov.reader data)
LIB="$DATA/Documents/Books"
rm -rf "$LIB"; mkdir -p "$LIB/Physics" "$LIB/Fiction"
cp "$SRC/Thermodynamics.pdf" "$SRC/Thermodynamics.djvu" "$LIB/Physics/"
[ -f "$SRC/Linked.pdf" ] && cp "$SRC/Linked.pdf" "$LIB/Physics/Linked.pdf"
cp "$SRC/Scanned.pdf" "$LIB/"
[ -f "$SRC/Entropy (Wikipedia).webarchive" ] && cp "$SRC/Entropy (Wikipedia).webarchive" "$LIB/"
[ -f "$SRC/Python 3.10 docs.chm" ] && cp "$SRC/Python 3.10 docs.chm" "$LIB/"
cp "$SRC/Pride.epub" "$LIB/Fiction/Pride and Prejudice.epub"
cp "$(dirname "$0")/../Packages/ReaderCore/Tests/ReaderCoreTests/Fixtures/sample.fb2" "$LIB/Fiction/Тепло и порядок.fb2"
# Without an iCloud account the app uses Documents/Inbox; leave two books there for the sync test.
INBOX="$DATA/Documents/Inbox"
rm -rf "$INBOX"; mkdir -p "$INBOX/Physics" "$INBOX/From Inbox"
cp "$SRC/Thermodynamics.pdf" "$INBOX/Physics/Thermodynamics (Inbox copy).pdf"
cp "$(dirname "$0")/../Packages/ReaderCore/Tests/ReaderCoreTests/Fixtures/sample3.epub" "$INBOX/From Inbox/Inbox Book.epub"
find "$LIB" "$INBOX" -type f | sed "s|$DATA/Documents/||"

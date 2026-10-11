#!/bin/bash
# Exercises Wi-Fi Transfer against a running Reader (simulator shares the Mac's network).
# Usage: scripts/transfer-smoke.sh <book-to-upload> [base-url]
set -euo pipefail
BOOK=${1:?book file}; BASE=${2:-http://127.0.0.1:8080}
for _ in $(seq 60); do curl -sf "$BASE/api/list" >/dev/null && break; sleep 1; done
curl -sf "$BASE/" | grep -q "Wi-Fi Transfer" && echo "page: ok"
curl -sf -X POST "$BASE/api/mkdir?path=&name=Uploaded" && echo
NAME=$(basename "$BOOK" | python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.stdin.read().strip()))')
curl -sf -X PUT --data-binary @"$BOOK" "$BASE/api/upload?path=Uploaded&name=$NAME" && echo
curl -sf "$BASE/api/list?path=Uploaded" && echo
curl -sf "$BASE/api/download?path=Uploaded/$NAME" -o /tmp/.reader-roundtrip && cmp -s /tmp/.reader-roundtrip "$BOOK" && echo "download: identical"
code=$(curl -s -o /dev/null -w '%{http_code}' "$BASE/api/list?path=../..") && echo "traversal: HTTP $code"

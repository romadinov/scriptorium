#!/bin/bash
# Builds the Mac app ad hoc (no iCloud), seeds its library with sample books and runs the Mac UI tests.
# Usage: scripts/test-mac.sh <dir-with-sample-books> [test name] ; screenshots go to $SCREENSHOT_DIR if set.
set -euo pipefail
cd "$(dirname "$0")/.."
SRC=${1:?folder with sample books}; ONLY=${2:-}
LIB="$HOME/Library/Containers/com.romadinov.reader.mac/Data/Documents/Books"
mkdir -p "$LIB/Physics" "$LIB/Fiction"
cp "$SRC/Thermodynamics.pdf" "$LIB/Physics/"
cp "$SRC/Thermodynamics.djvu" "$LIB/Physics/Thermodynamics (DjVu).djvu"
cp "$SRC/Pride.epub" "$LIB/Fiction/Pride and Prejudice.epub"
[ -f "$SRC/azw/Pride.azw3" ] && cp "$SRC/azw/Pride.azw3" "$LIB/Fiction/Pride and Prejudice (Kindle).azw3"
ARGS=(-project Reader.xcodeproj -scheme ScriptoriumMac -destination 'platform=macOS'
      CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER=
      MAC_ENTITLEMENTS=ScriptoriumMac-Local)
[ -n "$ONLY" ] && ARGS+=(-only-testing:"ScriptoriumMacUITests/MacFlowTests/$ONLY")
RESULT=$(mktemp -d)/mac.xcresult
status=0
xcodebuild test "${ARGS[@]}" -resultBundlePath "$RESULT" || status=$?
# The test runner is sandboxed; screenshots come out of the result bundle.
if [ -n "${SCREENSHOT_DIR:-}" ]; then
  mkdir -p "$SCREENSHOT_DIR"
  xcrun xcresulttool export attachments --path "$RESULT" --output-path "$SCREENSHOT_DIR" >/dev/null 2>&1 || true
  python3 - "$SCREENSHOT_DIR" <<'PY'
import json, os, sys
d = sys.argv[1]
try:
    manifest = json.load(open(os.path.join(d, "manifest.json")))
except Exception:
    sys.exit(0)
for test in manifest:
    for a in test.get("attachments", []):
        src = os.path.join(d, a["exportedFileName"])
        name = a.get("suggestedHumanReadableName", a["exportedFileName"]).split("_")[0]
        if os.path.exists(src): os.replace(src, os.path.join(d, name + ".png"))
PY
fi
exit $status

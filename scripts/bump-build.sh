#!/bin/bash
# Increments CURRENT_PROJECT_VERSION in project.yml and regenerates the Xcode project.
# Run before installing a build that changes Info.plist (iCloud caches it per build number).
set -euo pipefail
cd "$(dirname "$0")/.."
current=$(sed -nE 's/^ *CURRENT_PROJECT_VERSION: "?([0-9]+)"?.*/\1/p' project.yml | head -1)
next=$((current + 1))
sed -i '' -E "s/(CURRENT_PROJECT_VERSION: )\"?[0-9]+\"?/\1\"$next\"/" project.yml
xcodegen generate -q
echo "Build number: $current → $next"

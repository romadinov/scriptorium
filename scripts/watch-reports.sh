#!/bin/bash
# Background check (run by launchd, no model involved): lists open improvement notes and new crash
# reports, and posts a macOS notification only when something is waiting — once per distinct finding.
# Install/uninstall: scripts/watch-reports.sh --install | --uninstall
set -uo pipefail
cd "$(dirname "$0")/.."
LABEL=com.romadinov.scriptorium.watch-reports
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
STATE="$HOME/Library/Developer/Scriptorium"
mkdir -p "$STATE"

case "${1:-}" in
--install)
  # launchd jobs have no app identity, so macOS blocks them from iCloud Drive without asking. A tiny helper
  # app as the job's program can be granted access (macOS asks once); it just runs this script.
  APP="$STATE/ScriptoriumWatch.app"
  rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
  cat > "$APP/Contents/Info.plist" <<INFO
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>$LABEL</string>
  <key>CFBundleName</key><string>Scriptorium Watch</string>
  <key>CFBundleExecutable</key><string>ScriptoriumWatch</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSUIElement</key><true/>
</dict></plist>
INFO
  cat > "$STATE/ScriptoriumWatch.swift" <<SWIFT
import Foundation
let task = Process()
task.executableURL = URL(fileURLWithPath: "/bin/bash")
task.arguments = ["$PWD/scripts/watch-reports.sh"]
try task.run()
task.waitUntilExit()
exit(task.terminationStatus)
SWIFT
  swiftc -O "$STATE/ScriptoriumWatch.swift" -o "$APP/Contents/MacOS/ScriptoriumWatch" || exit 1
  codesign --force --sign - --identifier "$LABEL" "$APP" || exit 1
  cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$APP/Contents/MacOS/ScriptoriumWatch</string></array>
  <key>StartInterval</key><integer>1800</integer>
  <key>RunAtLoad</key><true/>
  <key>LowPriorityIO</key><true/>
  <key>ProcessType</key><string>Background</string>
  <key>StandardOutPath</key><string>$STATE/watch-reports.log</string>
  <key>StandardErrorPath</key><string>$STATE/watch-reports.log</string>
</dict></plist>
PLIST
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null
  launchctl bootstrap "gui/$(id -u)" "$PLIST" && echo "Installed: checks every 30 min; log in $STATE/watch-reports.log"
  exit ;;
--uninstall)
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null; rm -rf "$PLIST" "$STATE/ScriptoriumWatch.app"; echo "Uninstalled"; exit ;;
esac

export PATH=/usr/bin:/bin:/usr/sbin:/sbin
notes=$(swift scripts/mark-improvement-done.swift 2>&1)
crashes=$(swift scripts/crash-reports.swift 2>&1)
echo "$(date '+%F %T') notes: $(head -1 <<< "$notes") | crashes: $(head -1 <<< "$crashes")"

found=()
grep -q "^No open notes" <<< "$notes" || found+=("improvement notes")
grep -q "^No new crash reports" <<< "$crashes" || found+=("crash reports")
[ ${#found[@]} -eq 0 ] && { rm -f "$STATE/watch-reports.last"; exit 0; }

# Same findings as last time: don't notify again.
digest=$(printf '%s\n%s' "$notes" "$crashes" | shasum | cut -c1-40)
[ "$(cat "$STATE/watch-reports.last" 2>/dev/null)" = "$digest" ] && exit 0
echo "$digest" > "$STATE/watch-reports.last"
printf '%s\n\n%s\n' "$notes" "$crashes" > "$STATE/watch-reports-latest.txt"
what=$(IFS=" and "; echo "${found[*]}")
osascript -e "display notification \"New $what waiting. Ask Claude to check them.\" with title \"Scriptorium\" sound name \"Glass\""

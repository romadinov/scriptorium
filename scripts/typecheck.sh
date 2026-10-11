#!/bin/bash
# Type-checks the iPad app without Xcode by compiling against the Mac Catalyst UIKit
# that ships inside the macOS SDK (Command Line Tools are enough).
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT
SDK=$(xcrun --show-sdk-path)
TARGET=arm64-apple-ios26.0-macabi
FW=(-Fsystem "$SDK/System/iOSSupport/System/Library/Frameworks" -I "$SDK/System/iOSSupport/usr/lib/swift")
INC="$PWD/Packages/ReaderCore/Sources/CDjVuLibre/include"
mkdir -p "$OUT/cmod"
printf 'module CDjVuLibre { header "%s/ddjvuapi.h" header "%s/miniexp.h" export * }\n' "$INC" "$INC" > "$OUT/cmod/module.modulemap"

swiftc -target $TARGET -sdk "$SDK" "${FW[@]}" -swift-version 5 -parse-as-library \
  -module-name ReaderCore -emit-module -emit-module-path "$OUT/ReaderCore.swiftmodule" -I "$OUT/cmod" \
  $(find Packages/ReaderCore/Sources/ReaderCore -name '*.swift')
swiftc -target $TARGET -sdk "$SDK" "${FW[@]}" -swift-version 5 -parse-as-library -typecheck \
  -I "$OUT" -I "$OUT/cmod" $(find App -name '*.swift')
echo "Type-check OK"

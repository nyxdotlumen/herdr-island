#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache"
export SWIFT_MODULECACHE_PATH="$PWD/.build/swift-module-cache"
swift build -c release --product DynamicHerdr --disable-sandbox --cache-path "$PWD/.build/cache"
app="$PWD/dist/Herdr Island.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp .build/release/DynamicHerdr "$app/Contents/MacOS/DynamicHerdr"
cp -Rf .build/release/SwiftTerm_SwiftTerm.bundle "$app/Contents/Resources/"
cp -f .build/checkouts/SwiftTerm/LICENSE "$app/Contents/Resources/SwiftTerm-LICENSE"
cp Resources/Info.plist "$app/Contents/Info.plist"
codesign --force --deep --sign - "$app"
printf 'Built %s\n' "$app"

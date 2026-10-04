#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache"
export SWIFT_MODULECACHE_PATH="$PWD/.build/swift-module-cache"
swift run --disable-sandbox --cache-path "$PWD/.build/cache" IslandCoreChecks
swift run --disable-sandbox --cache-path "$PWD/.build/cache" NativeInputChecks

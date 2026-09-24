#!/usr/bin/env bash
# swift build, with SwiftPM and clang caches kept under .build so it also works in restricted shells.
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
exec swift build --disable-sandbox --cache-path .build/spm-cache "$@"

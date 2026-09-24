#!/usr/bin/env bash
# Builds a release Screenshelf.app into build/, ad-hoc signed.
set -euo pipefail
cd "$(dirname "$0")/.."

scripts/build.sh -c release --product Screenshelf
scripts/build.sh -c release --product shelf

if [[ ! -f Resources/AppIcon.icns || scripts/make-icon.swift -nt Resources/AppIcon.icns ]]; then
    CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache" swift -module-cache-path .build/module-cache scripts/make-icon.swift Resources/AppIcon.icns
fi

APP=build/Screenshelf.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Screenshelf "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
codesign --force --sign - --timestamp=none "$APP"
echo "Built $APP"

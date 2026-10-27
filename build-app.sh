#!/bin/sh
set -eu
swift build -c release
rm -rf WindowSwitcher.app
mkdir -p WindowSwitcher.app/Contents/MacOS WindowSwitcher.app/Contents/Resources
cp .build/release/WindowSwitcher WindowSwitcher.app/Contents/MacOS/WindowSwitcher
cp Info.plist WindowSwitcher.app/Contents/Info.plist
echo "Built WindowSwitcher.app"

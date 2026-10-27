#!/bin/sh
set -eu
swift build -c release
rm -rf WindowSwitcher.app
mkdir -p WindowSwitcher.app/Contents/MacOS WindowSwitcher.app/Contents/Resources
cp .build/release/WindowSwitcher WindowSwitcher.app/Contents/MacOS/WindowSwitcher
cp Info.plist WindowSwitcher.app/Contents/Info.plist
# Sign the complete bundle so TCC can associate permissions with its stable
# bundle identifier instead of only the linker-signed executable.
codesign --force --deep --sign - --identifier local.windowswitcher.app WindowSwitcher.app
echo "Built WindowSwitcher.app"

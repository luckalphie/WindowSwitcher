#!/bin/sh
set -eu
swift build -c release
rm -rf WindowSwitcher.app
mkdir -p WindowSwitcher.app/Contents/MacOS WindowSwitcher.app/Contents/Resources
cp .build/release/WindowSwitcher WindowSwitcher.app/Contents/MacOS/WindowSwitcher
cp Info.plist WindowSwitcher.app/Contents/Info.plist
cp AppIcon.icns WindowSwitcher.app/Contents/Resources/AppIcon.icns
# Sign with the persistent local identity so TCC can keep the same designated
# requirement across rebuilds. Fall back to ad-hoc only on a fresh machine.
signing_keychain="$HOME/Library/Keychains/login.keychain-db"
signing_identity="WindowSwitcher Local Signing"
if security find-certificate -c "$signing_identity" "$signing_keychain" >/dev/null 2>&1; then
  codesign --force --deep --sign "$signing_identity" --keychain "$signing_keychain" --identifier local.windowswitcher.app WindowSwitcher.app
else
  codesign --force --deep --sign - --identifier local.windowswitcher.app WindowSwitcher.app
fi
echo "Built WindowSwitcher.app"

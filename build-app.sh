#!/bin/sh
set -eu
swift build -c release
app_bundle="Window Switcher.app"
rm -rf "$app_bundle"
mkdir -p "$app_bundle/Contents/MacOS" "$app_bundle/Contents/Resources"
cp .build/release/WindowSwitcher "$app_bundle/Contents/MacOS/WindowSwitcher"
cp Info.plist "$app_bundle/Contents/Info.plist"
cp AppIcon.icns "$app_bundle/Contents/Resources/AppIcon.icns"
# Sign with the persistent local identity so TCC can keep the same designated
# requirement across rebuilds. Fall back to ad-hoc only on a fresh machine.
signing_identity="WindowSwitcher Local Signing"
if security find-certificate -c "$signing_identity" >/dev/null 2>&1; then
  codesign --force --deep --sign "$signing_identity" --identifier local.windowswitcher.app "$app_bundle"
else
  codesign --force --deep --sign - --identifier local.windowswitcher.app "$app_bundle"
fi
echo "Built $app_bundle"

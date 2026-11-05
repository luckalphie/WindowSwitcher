#!/bin/sh
set -eu
# TCC 以签名身份识别辅助功能权限。缺失固定身份时不能退回临时 ad-hoc 签名，
# 否则每次重新构建都会被 macOS 识别为新的应用并要求再次授权。
signing_identity="WindowSwitcher Local Signing"
if ! security find-certificate -c "$signing_identity" >/dev/null 2>&1; then
  echo "缺少签名证书：$signing_identity" >&2
  echo "请先在钥匙串访问中创建或导入该代码签名证书，再重新执行打包。" >&2
  exit 1
fi

swift build -c release
app_bundle="Window Switcher.app"
rm -rf "$app_bundle"
mkdir -p "$app_bundle/Contents/MacOS" "$app_bundle/Contents/Resources"
cp .build/release/WindowSwitcher "$app_bundle/Contents/MacOS/WindowSwitcher"
cp Info.plist "$app_bundle/Contents/Info.plist"
cp AppIcon.icns "$app_bundle/Contents/Resources/AppIcon.icns"
codesign --force --deep --sign "$signing_identity" --identifier local.windowswitcher.app "$app_bundle"
echo "Built $app_bundle"

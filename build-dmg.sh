#!/bin/sh
set -eu

./build-app.sh

version=$(plutil -extract CFBundleShortVersionString raw Info.plist)
output_dir="dist"
image_path="$output_dir/WindowSwitcher-$version-macos-arm64.dmg"
staging_dir=$(mktemp -d)
trap 'rm -rf "$staging_dir"' EXIT

# Finder 打开 DMG 时显示应用与 Applications 快捷方式，用户可直接拖拽安装。
cp -R "$output_dir/Window Switcher.app" "$staging_dir/Window Switcher.app"
ln -s /Applications "$staging_dir/Applications"
rm -f "$image_path"
hdiutil create -volname "Window Switcher" -srcfolder "$staging_dir" -format UDZO -ov "$image_path"
echo "Built $image_path"

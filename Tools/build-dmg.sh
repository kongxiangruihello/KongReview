#!/bin/bash
# 不依赖 Xcode，只用 Apple 命令行工具构建 KongGlean.app 并打包成 DMG。
# 用法：在仓库根目录执行  ./Tools/build-dmg.sh
# 产物：与仓库同级的 KongGlean-<版本>.dmg（例如 ~/Documents/KongGlean-0.2.0.dmg）
# 旧产物不覆盖、不删除：移到同级的“KongGlean旧构建/<时间>/”里。
set -euo pipefail
cd "$(dirname "$0")/.."

APP="KongGlean"
BUNDLE_ID="com.kongxiangrui.KongGlean"
VERSION="$(grep -m1 'MARKETING_VERSION' project.yml | sed -E 's/.*"([^"]+)".*/\1/')"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
OUT="build"
APP_DIR="$OUT/$APP.app"
FINAL_DMG="../$APP-$VERSION.dmg"

echo "==> 检查工具链"
if ! xcode-select -p >/dev/null 2>&1; then
  echo "未找到命令行工具。请先执行：xcode-select --install，安装完成后重新运行本脚本。"
  exit 1
fi
swift --version

echo "==> 归档上一次的产物（版本 $VERSION）"
ARCHIVE="../${APP}旧构建/$(date +%Y%m%d-%H%M%S)"
for f in "$OUT" "$FINAL_DMG"; do
  if [ -e "$f" ]; then
    mkdir -p "$ARCHIVE"
    mv -n "$f" "$ARCHIVE/"
    echo "已移走：$f → $ARCHIVE"
  fi
done

echo "==> 编译（Release，arm64）"
swift build -c release --arch arm64 --product "$APP"
BIN_DIR="$(swift build -c release --arch arm64 --show-bin-path)"

echo "==> 组装 $APP.app"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_DIR/$APP" "$APP_DIR/Contents/MacOS/$APP"
# SwiftPM 生成的资源包（如 GRDB 的隐私清单）
find "$BIN_DIR" -maxdepth 1 -name '*.bundle' -exec cp -R {} "$APP_DIR/Contents/Resources/" \;

echo "==> 生成图标"
ICONSET="$OUT/AppIcon.iconset"
mkdir -p "$ICONSET"
cp KongGlean/Resources/Assets.xcassets/AppIcon.appiconset/icon_*.png "$ICONSET/"
iconutil -c icns "$ICONSET" -o "$APP_DIR/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>zh-Hans</string>
  <key>CFBundleExecutable</key><string>$APP</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>$APP</string>
  <key>CFBundleDisplayName</key><string>$APP</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>© 孔祥瑞</string>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key><string>$BUNDLE_ID</string>
      <key>CFBundleURLSchemes</key><array><string>kongglean</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST

echo "==> 本机签名（ad-hoc）"
codesign --force --deep --sign - "$APP_DIR"
codesign --verify --verbose=1 "$APP_DIR"

echo "==> 打包 DMG"
STAGE="$OUT/dmg"
mkdir -p "$STAGE"
cp -R "$APP_DIR" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
DMG="$OUT/$APP-$VERSION.dmg"
hdiutil create -volname "$APP $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
cp "$DMG" "$FINAL_DMG"

echo ""
echo "完成：$(cd .. && pwd)/$APP-$VERSION.dmg"

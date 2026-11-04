#!/bin/bash
# 6.0.2：编译 KongReview.app（仿 KongSeek 的 scripts/build-app.sh）。应用内“立即更新”、DMG 打包与首次安装都用它。
#
#   Tools/build-app.sh             只编译，产物在 build/KongReview.app
#   Tools/build-app.sh --test      先跑全部测试（核心包与应用），不通过就停
#   Tools/build-app.sh --install   编译后退出正在运行的 KongReview，装到“应用程序”并打开
#
# 签名：钥匙串里有“KongReview Local Signing”（或 KongSeek / KongFetch 的同类证书，或 $KONGREVIEW_SIGN_IDENTITY）就用它，
# 这样更新后 macOS 仍当作同一个应用、已授予的权限不丢；没有就本机签名（ad hoc）。
# 输出同时写进 build/build.log。下面“== tests ==”等几行是给应用里的进度条看的，请勿改动。
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"
mkdir -p build
log="$root/build/build.log"
exec > >(tee "$log") 2>&1

install=0
test=0
for arg in "$@"; do
  case "$arg" in
    --install) install=1 ;;
    --test) test=1 ;;
    *) echo "unknown option: $arg"; exit 2 ;;
  esac
done

bundle_id="com.kongxiangrui.KongReview"
version="$(grep -m1 'MARKETING_VERSION' project.yml | sed -E 's/.*"([^"]+)".*/\1/')"
build_number="$(git -C "$root" rev-list --count HEAD 2>/dev/null || echo 1)"

echo "== KongReview build $(date '+%Y-%m-%d %H:%M:%S') =="
echo "版本 ${version}（构建 ${build_number}）"
sw_vers -productVersion | sed 's/^/macOS /'
if ! xcrun --find swift >/dev/null 2>&1; then
  echo "未找到 Swift 命令行工具。请先执行：xcode-select --install，装好后再试。"
  exit 1
fi
xcrun swift --version 2>&1 | head -1

# 6.3：同一份源码（git 树）在本机用同一版 Swift 测过、全部通过，就不再测一遍（“测试KongReview.command”与这里都记）。
# 树相同即每个文件都相同；GitHub 上合并 PR 产生的提交，树与测过的分支末端相同。
tested_file="$HOME/Library/Caches/KongReview-updates/tested-trees.txt"
mkdir -p "$(dirname "$tested_file")"
tree="$(git -C "$root" rev-parse 'HEAD^{tree}' 2>/dev/null || true)"
swift_id="$(xcrun swift --version 2>&1 | head -1 | shasum | cut -c1-12)"
stamp="$tree $swift_id"
clean=0
[[ -n "$tree" && -z "$(git -C "$root" status --porcelain 2>/dev/null)" ]] && clean=1

if [[ $test -eq 1 ]]; then
  echo "== tests =="
  if [[ $clean -eq 1 && -f "$tested_file" ]] && grep -qxF "$stamp" "$tested_file"; then
    echo "这份源码（树 ${tree:0:7}）已在本机用同一版 Swift 测过、全部通过，这次不再测。"
  else
    # 先把应用的测试编译好，再测核心包、应用（测应用时不必再编译，进度不会卡住）
    xcrun swift build --build-tests
    (cd Packages/KongReviewCore && xcrun swift test)
    xcrun swift test --skip-build
    if [[ $clean -eq 1 ]]; then echo "$stamp" >> "$tested_file"; fi
  fi
fi

echo "== compile =="
xcrun swift build -c release --arch arm64 --product KongReview
bin_dir="$(xcrun swift build -c release --arch arm64 --show-bin-path)"

# 在临时目录里组装与签名：“文稿”若开启了 iCloud 同步，文件会带扩展属性，codesign 会拒绝
staging="$(mktemp -d "${TMPDIR:-/tmp}/kongreview-build.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
app="$staging/KongReview.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin_dir/KongReview" "$app/Contents/MacOS/KongReview"
# SwiftPM 生成的资源包（如 GRDB 的隐私清单）
find "$bin_dir" -maxdepth 1 -name '*.bundle' -exec cp -R {} "$app/Contents/Resources/" \;

echo "== icon =="
iconset="$staging/AppIcon.iconset"
mkdir -p "$iconset"
cp KongReview/Resources/Assets.xcassets/AppIcon.appiconset/icon_*.png "$iconset/"
iconutil -c icns "$iconset" -o "$app/Contents/Resources/AppIcon.icns"
rm -rf "$iconset"

cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>zh-Hans</string>
  <key>CFBundleExecutable</key><string>KongReview</string>
  <key>CFBundleIdentifier</key><string>$bundle_id</string>
  <key>CFBundleName</key><string>KongReview</string>
  <key>CFBundleDisplayName</key><string>KongReview</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>$build_number</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>© 孔祥瑞</string>
  <key>NSAppleEventsUsageDescription</key><string>从浏览器录入摘录时读取当前标签页的网址，自动填入出处。</string>
  <key>NSAppTransportSecurity</key>
  <dict>
    <key>NSAllowsArbitraryLoads</key><true/>
  </dict>
  <key>NSServices</key>
  <array>
    <dict>
      <key>NSMenuItem</key><dict><key>default</key><string>添加到 KongReview</string></dict>
      <key>NSMessage</key><string>addHighlight</string>
      <key>NSPortName</key><string>KongReview</string>
      <key>NSSendTypes</key><array><string>public.html</string><string>public.rtf</string><string>public.utf8-plain-text</string><string>NSStringPboardType</string></array>
      <key>NSRequiredContext</key><dict/>
    </dict>
  </array>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key><string>$bundle_id</string>
      <key>CFBundleURLSchemes</key><array><string>kongreview</string><string>kongglean</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST

# 这一版来自哪个提交（源码没有本地改动时才记），供应用里“检查更新”列出新的改动
commit=""
if [[ -z "$(git -C "$root" status --porcelain 2>/dev/null)" ]]; then
  commit="$(git -C "$root" rev-parse HEAD 2>/dev/null || true)"
fi
if [[ -n "$commit" ]]; then
  plutil -insert KRSourceCommit -string "$commit" "$app/Contents/Info.plist"
  echo "源码：$root @ ${commit:0:7}"
else
  echo "源码：${root}（有本地改动，未记提交号）"
fi

xattr -cr "$app"

echo "== sign =="
identity=""
for candidate in "${KONGREVIEW_SIGN_IDENTITY:-}" "KongReview Local Signing" "KongSeek Local Signing" "KongFetch Local Signing"; do
  [[ -z "$candidate" ]] && continue
  if security find-identity -p codesigning 2>/dev/null | grep -Fq "\"$candidate\""; then
    identity="$candidate"
    break
  fi
done
if [[ -n "$identity" ]]; then
  codesign --force --deep --sign "$identity" --identifier "$bundle_id" "$app"
  echo "签名：$identity"
else
  codesign --force --deep --sign - --identifier "$bundle_id" "$app"
  echo "签名：本机（ad hoc）"
fi
codesign --verify --verbose=1 "$app" || echo "注意：codesign --verify 有提示（自签证书时属正常）。"

rm -rf "$root/build/KongReview.app"
ditto "$app" "$root/build/KongReview.app"
echo "Built: $root/build/KongReview.app"

if [[ $install -eq 1 ]]; then
  echo "== install =="
  osascript -e "tell application id \"$bundle_id\" to quit" >/dev/null 2>&1 || true
  for i in $(seq 1 25); do pgrep -x KongReview >/dev/null 2>&1 || break; sleep 0.2; done
  pkill -x KongReview >/dev/null 2>&1 || true
  # 装之前先备份学习库（应用已退出，用 SQLite 的在线备份，连同尚未合并的 WAL 内容）
  data="$HOME/Library/Application Support/KongReview/kongreview.sqlite"
  if [[ -f "$data" ]]; then
    keep="$HOME/Library/Application Support/KongReview/安装前备份"
    mkdir -p "$keep"
    copy="$keep/kongreview-$(date +%Y%m%d-%H%M%S).sqlite"
    if sqlite3 "$data" ".backup '$copy'" 2>/dev/null; then echo "学习库已备份：$copy"; else cp "$data" "$copy" && echo "学习库已复制：$copy"; fi
  fi
  if [[ -d /Applications/KongReview.app ]]; then
    backups="$HOME/Library/Application Support/KongReview/应用备份"
    mkdir -p "$backups"
    old="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' /Applications/KongReview.app/Contents/Info.plist 2>/dev/null || echo old)"
    oldbuild="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' /Applications/KongReview.app/Contents/Info.plist 2>/dev/null || echo 0)"
    rm -rf "$backups/KongReview-$old-$oldbuild.app"
    mv /Applications/KongReview.app "$backups/KongReview-$old-$oldbuild.app"
    echo "旧版本移到：$backups/KongReview-$old-$oldbuild.app"
  fi
  ditto "$app" /Applications/KongReview.app
  xattr -cr /Applications/KongReview.app
  open /Applications/KongReview.app
  echo "Installed: /Applications/KongReview.app"
fi

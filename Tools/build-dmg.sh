#!/bin/bash
# 不依赖 Xcode，只用 Apple 命令行工具构建 KongReview.app 并打包成 DMG。
# 用法：在仓库根目录执行  ./Tools/build-dmg.sh
# 产物：与仓库同级的 KongReview-<版本>.dmg（例如 ~/Documents/KongReview-0.2.0.dmg）
# 旧产物不覆盖、不删除：移到同级的“KongReview旧构建/<时间>/”里。
set -euo pipefail
cd "$(dirname "$0")/.."

APP="KongReview"
BUNDLE_ID="com.kongxiangrui.KongReview"
VERSION="$(grep -m1 'MARKETING_VERSION' project.yml | sed -E 's/.*"([^"]+)".*/\1/')"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
OUT="build"
# 在临时目录里组装与签名：“文稿”若开启了 iCloud 同步，文件会被加上扩展属性，
# codesign 会报 “resource fork, Finder information, or similar detritus not allowed”。
WORK="$(mktemp -d "${TMPDIR:-/tmp}/kongreview-build.XXXXXX")"
APP_DIR="${WORK}/${APP}.app"
# 6.3：设了 KONGREVIEW_DMG_DIR（如测试脚本放到缓存目录）时，产物放那里、同版本直接覆盖，不归档旧产物
DMG_DIR="${KONGREVIEW_DMG_DIR:-..}"
mkdir -p "${DMG_DIR}"
FINAL_DMG="${DMG_DIR}/${APP}-${VERSION}.dmg"

echo "==> 检查工具链"
if ! xcode-select -p >/dev/null 2>&1; then
  echo "未找到命令行工具。请先执行：xcode-select --install，安装完成后重新运行本脚本。"
  exit 1
fi
swift --version

if [ -n "${KONGREVIEW_DMG_DIR:-}" ]; then
  echo "==> 清掉上一次的产物（输出到 ${DMG_DIR}，同版本覆盖）"
  rm -rf "${OUT}" "${FINAL_DMG}"
else
  echo "==> 归档上一次的产物（版本 ${VERSION}）"
  ARCHIVE="../${APP}旧构建/$(date +%Y%m%d-%H%M%S)"
  for f in "${OUT}" "${FINAL_DMG}"; do
    if [ -e "${f}" ]; then
      mkdir -p "${ARCHIVE}"
      mv -n "${f}" "${ARCHIVE}/"
      echo "已移走：${f} → ${ARCHIVE}"
    fi
  done
fi

echo "==> 编译并签名（Tools/build-app.sh）"
bash Tools/build-app.sh
mkdir -p "${WORK}"
ditto "${OUT}/${APP}.app" "${APP_DIR}"
xattr -cr "${APP_DIR}"
codesign --verify --verbose=1 "${APP_DIR}"

echo "==> 打包 DMG"
STAGE="${WORK}/dmg"
mkdir -p "${STAGE}"
cp -R "${APP_DIR}" "${STAGE}/"
ln -s /Applications "${STAGE}/Applications"
mkdir -p "${OUT}"
DMG="${OUT}/${APP}-${VERSION}.dmg"
hdiutil create -volname "${APP} ${VERSION}" -srcfolder "${STAGE}" -ov -format UDZO "${DMG}" >/dev/null
rm -rf "${WORK}"
cp "${DMG}" "${FINAL_DMG}"

echo ""
echo "完成：$(cd "${DMG_DIR}" && pwd)/${APP}-${VERSION}.dmg"

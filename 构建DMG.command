#!/bin/bash
# 在访达中双击即可：编译 KongGlean 并生成 DMG，完成后自动打开 build 文件夹。
cd "$(dirname "$0")"
if ./Tools/build-dmg.sh; then
  open build
else
  echo ""
  echo "构建失败，请把上面的报错发给 Claude。"
fi
echo ""
read -n 1 -s -r -p "按任意键关闭窗口…"

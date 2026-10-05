#!/bin/bash
# 在访达中双击即可：编译 KongGlean 并生成 DMG，完成后自动打开 build 文件夹。
# 全部输出同时写入 build.log，出错时可把日志发给 Claude。
cd "$(dirname "$0")"
if ./Tools/build-dmg.sh 2>&1 | tee build.log; [ "${PIPESTATUS[0]}" -eq 0 ]; then
  open build
else
  echo ""
  echo "构建失败，日志已保存在 build.log。"
fi
echo ""
read -n 1 -s -r -p "按任意键关闭窗口…"

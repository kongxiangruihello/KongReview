#!/bin/bash
# 双击运行：第一次安装“点一下就更新”的 KongReview，或应用打不开时重装。
# 把源码放到 ~/Developer/KongReview（已有就换成 GitHub 上 main 分支的最新代码），跑完全部测试后编译，
# 备份学习库，再装到“应用程序”并打开。平时更新不用它：在应用里点菜单“KongReview → 检查更新…”。
# 输出同时写进 ~/Developer/KongReview/build/build.log。
src="$HOME/Developer/KongReview"
url="https://github.com/kongxiangruihello/KongReview.git"
branch="${KONGREVIEW_BRANCH:-main}"
finish() { echo; read -n 1 -s -r -p "按任意键关闭窗口…"; exit "${1:-0}"; }

GITOPTS=(-c http.lowSpeedLimit=1000 -c http.lowSpeedTime=60)
PROXY_HOST=$(scutil --proxy 2>/dev/null | awk '/HTTPSProxy/ {print $3}')
PROXY_PORT=$(scutil --proxy 2>/dev/null | awk '/HTTPSPort/ {print $3}')
PROXY_ON=$(scutil --proxy 2>/dev/null | awk '/HTTPSEnable/ {print $3}')
if [ "$PROXY_ON" = "1" ] && [ -n "$PROXY_HOST" ] && [ -n "$PROXY_PORT" ]; then
  echo "→ 使用系统代理 http://$PROXY_HOST:$PROXY_PORT"
  GITOPTS+=(-c "http.proxy=http://$PROXY_HOST:$PROXY_PORT")
fi

echo "→ 第 1 步：准备源码（${src}，分支 ${branch}）"
if [ -d "$src/.git" ]; then
  cd "$src" || finish 1
  if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
    echo "源码文件夹里有改过的文件，为免丢失没有动它："; git status --short --untracked-files=no; finish 1
  fi
  git "${GITOPTS[@]}" fetch origin "$branch" || { echo "从 GitHub 获取失败，请检查网络或代理。"; finish 1; }
  git checkout -q -B "$branch" FETCH_HEAD || finish 1
else
  mkdir -p "$(dirname "$src")"
  git "${GITOPTS[@]}" clone --branch "$branch" "$url" "$src" || { echo "从 GitHub 下载失败，请检查网络或代理。"; finish 1; }
  cd "$src" || finish 1
fi
git log --oneline -1

echo "→ 第 2 步：测试、编译、备份学习库并安装（约几分钟）"
if bash Tools/build-app.sh --test --install; then
  echo; echo "完成。KongReview 已安装并打开；以后在应用里点“检查更新…”即可更新。"
  finish 0
else
  echo; echo "没有完成（当前安装的版本没有改动）。详细信息在 $src/build/build.log。"
  finish 1
fi

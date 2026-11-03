# 发布新版本（6.0.2 起：点一下就更新）

6.0.2 起不再需要 GitHub Releases（仿 KongSeek）。应用在本机的源码文件夹 `~/Developer/KongReview` 里取 GitHub 上 **main 分支** 的最新代码，自己测试、编译、安装。所以：

1. `project.yml` 的 `MARKETING_VERSION` 改为新版本号，README 顶部加一节 `## <版本> 标题`（应用的更新面板显示这些节）。
2. 在 GitHub 上把 PR 合并到 `main`。
3. 应用里菜单“KongReview → 检查更新…”（或等自动检查，首页会提示），点“立即更新”。

应用的判断：

- GitHub 上 `project.yml` 的版本号比本机新，或者有本机这一版之后的新提交（不算合并提交），就算有更新。
- 更新时：`git fetch origin main` → 源码文件夹换到 `origin/main`（自己改过、与任何已发布版本都不同的文件会让更新停下）→ `Tools/build-app.sh --test`（核心包与应用的全部测试，再编译 Release、签名）→ 核对新版本的标识、版本号与签名（当前用证书签名时须满足同一签名要求）→ 备份学习库 → 退出，助手脚本把当前版本移到 `~/Library/Application Support/KongReview/应用备份/`，换上新版并重新打开。
- 连不上 GitHub 时经代理：设置里填的，否则系统代理。
- 设置“更新”页还有“用本地源码重新构建”“回退到上一版”“更新日志”（`~/Library/Caches/KongReview-updates/update.log`；构建日志在源码文件夹的 `build/build.log`）。

第一次（或应用打不开时）：双击仓库根目录的 `安装KongReview.command`，它把源码放到 `~/Developer/KongReview`，跑完测试后编译、备份学习库并安装。

签名：钥匙串里有“KongReview Local Signing”（或 KongSeek / KongFetch 的同名证书）时 `Tools/build-app.sh` 用它签名，更新后 macOS 仍当作同一个应用；没有则本机签名（ad hoc）。

DMG 仍可用 `./Tools/build-dmg.sh` 生成（内部调用 `Tools/build-app.sh`），用于拷到别的 Mac。

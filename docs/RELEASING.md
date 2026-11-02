# 发布新版本（在线更新用）

应用读取 `https://api.github.com/repos/kongxiangruihello/KongReview/releases/latest`，所以仓库须为公开。

1. `project.yml` 的 `MARKETING_VERSION` 改为新版本号（如 `5.2.2`），README 写本版改动。
2. 在 Mac 上运行 `./Tools/build-dmg.sh`，得到 `KongReview-<版本>.dmg`（ad-hoc 签名）。
3. 在 GitHub 上新建 Release：
   - 标签 `v<版本>`，指向已合并到 `main` 的提交；
   - 标题为版本号；说明写本版改动（Markdown，显示在应用的更新面板里）；
   - 附件上传 `KongReview-<版本>.dmg`，文件名必须以 `KongReview` 开头、以 `.dmg` 结尾；
   - 不要勾选 Pre-release，也不要留成草稿（应用会跳过）。
4. 应用比较版本号（逐段数字比较），新版大于当前版本才提示；下载后核对文件大小与 GitHub 给出的 SHA-256 摘要，安装前核对安装包中应用的标识（`com.kongxiangrui.KongReview`）与版本号须与标签一致。

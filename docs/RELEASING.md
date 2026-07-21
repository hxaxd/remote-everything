# 本地发行

仓库的 `Release` GitHub Actions 工作流停用期间，Windows 维护机使用 `scripts/release-local.ps1` 完成主要验证、跨平台 Go 构建、Android 正式签名、校验清单和 GitHub Release 发布。

## 签名材料

脚本默认读取：

- `Documents/key/android-release-v2.jks`
- `Documents/key/android-release-v2.password.clixml`

密码文件由 Windows DPAPI 保护，只能由创建它的 Windows 用户在原系统身份下解密。两份文件都不得提交；密钥和可恢复密码必须另行离线备份。丢失签名密钥或密码后，已安装客户端无法再原地升级。

## 使用

本机还需要 `staticcheck` v0.7.0、`govulncheck` v1.6.0 和 `gitleaks` v8.30.1。前两项可由 Go 安装；Gitleaks 应从官方 Release 下载并按官方校验清单验证。脚本也会识别仓库本地 `.runtime/bin/gitleaks-8.30.1/gitleaks.exe`。

在仓库根目录运行：

```powershell
# 只运行共享契约、Skills、Go、Android 与当前主机可执行的检查
pwsh ./scripts/release-local.ps1 -Mode Validate

# 验证并生成完整本地资源，不访问 GitHub Release
pwsh ./scripts/release-local.ps1 -Mode Build

# 当前提交已有远端标签时，创建隐藏草稿并上传资源
pwsh ./scripts/release-local.ps1 -Mode Draft

# 在 main 的已合并提交上创建标签、推送并发布正式资源
pwsh ./scripts/release-local.ps1 -Mode Publish -CreateTag
```

如果同版本草稿已经存在，只有明确传入 `-ClobberAssets` 才会覆盖草稿资源。已发布 Release 不允许覆盖。

## 覆盖范围

脚本执行：

- 三端共享协议、版本和 HarmonyOS 源码/清单校验；
- Skills、运行记录夹具和部署脚本测试；
- Go 格式、静态检查、漏洞检查、单元测试和 Windows 节点集成测试；
- 使用 Gitleaks 扫描完整 Git 历史；
- Android 单元测试、lint、调试构建、正式签名构建与 APK 内容检查；
- Windows、Linux、macOS 的 amd64/arm64 节点和 LAN 服务端交叉构建；
- Linux amd64/arm64 公网网关构建；
- 固定资源集、Android 证书指纹和 SHA-256 校验清单检查；
- Git 标签、草稿上传和正式 GitHub Release 发布。

Windows 不能替代 macOS 上的 Xcode/iOS 模拟器测试。脚本只在 macOS 且已安装 Xcode 与 XcodeGen 时运行原生 iOS 检查；否则明确报告跳过。HarmonyOS 的 DevEco Studio/Hvigor 完整构建和三端真机验收仍需在对应工具和设备上执行。

# 发布资产

默认来源：`https://github.com/hxaxd/remote-everything/releases/latest`。同一次安装的项目组件和三端客户端版本使用同一标签。

## 资产名

```text
app-release.apk
remote-everything-control-windows-amd64.exe
remote-everything-control-windows-arm64.exe
remote-everything-control-linux-amd64
remote-everything-control-linux-arm64
remote-everything-control-macos-amd64
remote-everything-control-macos-arm64
remote-everything-lan-server-windows-amd64.exe
remote-everything-lan-server-windows-arm64.exe
remote-everything-lan-server-linux-amd64
remote-everything-lan-server-linux-arm64
remote-everything-lan-server-macos-amd64
remote-everything-lan-server-macos-arm64
remote-everything-gateway-linux-amd64
remote-everything-gateway-linux-arm64
SHA256SUMS
```

下载 `SHA256SUMS` 和所需节点/服务端资产，校验摘要后写入 `.runtime/bin/`；Unix 可执行文件设置 `0755`。Android 的 `app-release.apk` 交给用户或客户端更新器，不写入节点运行目录。iOS 与 HarmonyOS 的取得方式见 [mobile-clients.md](mobile-clients.md)。将标签、组件下载地址和 SHA-256 写入运行记录。

Release 缺少目标节点/服务端资产时，向用户提供“使用当前源码构建”或“等待完整发布”两种选择。源码构建只用于用户明确选择的开发版本：`GOOS=<目标平台> go build ./nodes/<平台>` 或 `./server/<形态>`；Windows 节点构建保留 `-ldflags=-H=windowsgui`。移动客户端缺少对应分发版本时按 [mobile-clients.md](mobile-clients.md) 处理，不代签、不降低来源校验。

FRP 固定为 `v0.70.0`，Caddy 固定为 `v2.11.4`。均从官方发布下载，校验官方摘要，并在运行记录中保存来源、版本和文件路径。

## 本地构建与发布

Release 可以走 `.github/workflows/release.yml`；CI 不可用或需要本地出包时，Windows 维护机使用 `scripts/release-local.ps1` 完成验证、跨平台 Go 构建、Android 签名、校验清单和 GitHub Release 发布。

### 签名材料

脚本默认读取 `Documents/key/android-release-v2.jks` 和 `Documents/key/android-release-v2.password.clixml`。密码文件由 Windows DPAPI 保护。两份文件不得提交；丢失签名密钥或密码后已安装客户端无法升级。

### 前置工具

需要 `staticcheck` v0.7.0、`govulncheck` v1.6.0 和 `gitleaks` v8.30.1。前两项通过 Go 安装；Gitleaks 从官方 Release 下载校验，脚本也会识别 `.runtime/bin/gitleaks-8.30.1/gitleaks.exe`。

### 使用

```powershell
pwsh ./scripts/release-local.ps1 -Mode Validate     # 契约/技能/Go/Android/Windows 本地检查
pwsh ./scripts/release-local.ps1 -Mode Build        # 验证并生成完整本地资产
pwsh ./scripts/release-local.ps1 -Mode Draft        # 已有远端标签时创建草稿并上传
pwsh ./scripts/release-local.ps1 -Mode Publish -CreateTag  # 创建标签、推送并发布正式资源
```

已有草稿存在时只有传 `-ClobberAssets` 才会覆盖。已发布 Release 不可变。

### 覆盖

脚本执行：契约+版本校验、Skills 测试、Go 检查与测试、Gitleaks 全历史扫描、Android 构建签名、三平台双架构 Go 交叉构建、资产清单校验、Git 标签与 Release 发布。Windows 不能跑 macOS/iOS 检查，脚本仅在 macOS+Xcode 环境下执行原生 iOS 测试；HarmonyOS 完整构建仍需 DevEco Studio。

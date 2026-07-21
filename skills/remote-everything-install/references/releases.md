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

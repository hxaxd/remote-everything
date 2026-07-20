# 发布资产

默认来源：`https://github.com/hxaxd/remote-everything/releases/latest`。同一次安装的项目组件与 APK 使用同一标签。

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

下载 `SHA256SUMS` 和所需资产，校验摘要后写入 `.runtime/bin/`；Unix 可执行文件设置 `0755`。将标签、下载地址和 SHA-256 写入运行记录。

Release 缺少目标资产时，向用户提供“使用当前源码构建”或“等待完整发布”两种选择。源码构建只用于用户明确选择的开发版本；Windows 节点构建保留 `-ldflags=-H=windowsgui`。

FRP 固定为 `v0.70.0`，Caddy 固定为 `v2.11.4`。均从官方发布下载，校验官方摘要，并在运行记录中保存来源、版本和文件路径。

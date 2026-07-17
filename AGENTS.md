# Agent Remote 接手与运维约定

本文是本项目的代理接手说明。开始修改前先通读本文和根目录 `README.md`。`README.md` 只负责从零复现整条链路；本文记录架构边界、故障经验和交付规则。部署相关的具体地址、指纹、密钥等实例信息记录在本地的 `AGENTS.local.md`（不入库）。

## 项目范围

- 文档集中在本文件、`README.md`、`PLAN.md`，不新增其他说明文档；源码中也不要堆积解释性注释。
- 不使用 `git reset --hard` 或 `git checkout --` 等破坏性命令覆盖用户文件。
- 鸿蒙、华为相关源码、工具和系统残留已按用户要求删除。除非用户明确反悔，不得重新引入。
- 不自行扩展接入新的被控应用；接入须用户明确要求。
- 用户偏好命令行操作，不要未经要求操作桌面界面。

## 当前架构

完整请求链路：

1. Android/iOS 客户端使用已批准的客户端证书连接公网服务器 `<公网服务器>:443`。
2. Caddy 负责 HTTPS、双向 TLS、证书边界和反向代理。
3. 云端 `kimi-gateway-status` 提供应用目录、状态、启动和停止接口。
4. 云端通过现有反向隧道 `127.0.0.1:58628` 访问 Windows 的本地网关 `127.0.0.1:58627`。
5. Windows 本地网关控制被控应用（默认 Kimi Web，监听 `127.0.0.1:58632`）。
6. 独立 SSH 维护通道（云端 `127.0.0.1:58630` → Windows `58626`）只用于维护和兜底，不参与每次应用状态请求。

端口约定：

| 位置 | 地址 | 用途 |
| --- | --- | --- |
| 公网服务器 | `0.0.0.0:443` | Caddy HTTPS/mTLS 入口 |
| 公网服务器 | `127.0.0.1:58629` | 状态服务 |
| 公网服务器 | `127.0.0.1:58631` | 设备注册服务 |
| 公网服务器 | `127.0.0.1:58628` | 反向隧道到 Windows `58627` |
| 公网服务器 | `127.0.0.1:58630` | 反向隧道到 Windows `58626`（维护/兜底） |
| Windows | `127.0.0.1:58627` | 本地路由与控制服务 |
| Windows | `127.0.0.1:58632` | 被控应用 Web |
| Windows | `127.0.0.1:58626` | 专用本地 sshd，仅维护/兜底 |

云端 systemd 服务：

- `caddy`
- `kimi-gateway-status`
- `kimi-enrollment`

Windows 计划任务：

- `AgentRemote-Apps`：直接启动 `%LOCALAPPDATA%\AgentRemote\agent-remote-control.exe serve`。程序必须保持 Windows GUI 子系统构建。
- `AgentRemote-LocalControl`：通过 `wscript.exe` 和 `run-control-hidden.vbs` 启动专用 sshd。
- `AgentRemote-Tunnel`：通过 `wscript.exe` 和 `run-tunnel-hidden.vbs` 启动反向隧道。

Windows 状态目录：

- 根目录：`%LOCALAPPDATA%\AgentRemote`
- 日志：`%LOCALAPPDATA%\AgentRemote\logs`
- 应用注册：`%LOCALAPPDATA%\AgentRemote\apps.json`
- 本地控制令牌：`%LOCALAPPDATA%\AgentRemote\control-token`

## 安全边界

- Caddy 全局要求 mTLS。引导证书只能访问设备注册接口，不能访问应用接口。
- 已批准的普通设备证书访问应用接口时还必须携带 Bearer 令牌。
- Windows 的 `POST /__local_agent_control` 必须验证本地控制令牌、只接受 POST、限制请求体大小，并使用常量时间比较。
- Caddy 必须明确对公网 `/__local_agent_control` 返回 `403`。该路径只能经云端本机反向隧道访问。
- `%LOCALAPPDATA%\AgentRemote\control-token` 必须移除继承权限，仅给当前用户完全控制。
- 云端敏感位置包括：
  - `/etc/kimi-gateway/control-token`
  - `/root/agent-remote-bundle/config.json`（必须保持 `0600`）
  - `/etc/kimi-gateway/approved-clients`
  - `/etc/kimi-gateway/client-trust.pem`
  - `/var/lib/kimi-enrollment/requests`
- 不得把控制令牌、客户端私钥、PKCS#12、注册口令、证书私钥或完整配置输出到聊天、日志、提交或本文。
- 升级客户端时覆盖安装相同包名和签名，不要卸载应用，否则会丢失本机凭据和状态。
- 客户端连接参数（主机、令牌、引导口令/指纹）不入库：Android 由 `configure-clients.ps1` 生成被 gitignore 的 `android/agent-remote.properties`（经 BuildConfig 注入），iOS 由同一脚本填充 `AppConfig.swift`。

## Android 交互约定

- 版本号以 `android/app/build.gradle.kts` 为准。
- 主要文件均在 `android/app/src/main/java/com/agentremote/app/`：`MainActivity.kt`、`DeviceIdentity.kt`、`SecureHttp.kt`、`AppConfig.kt`。
- 首屏是动态应用目录，可以启动、停止和进入应用。
- 进入应用后必须是纯 Web 全屏，不显示悬浮目录、连接状态或关机按钮。
- 从左边缘或右边缘向内滑，或执行系统返回手势，打开侧边菜单。
- 侧边菜单当前只有“返回目录”；启动和停止只放在应用目录。
- `MainActivity.kt` 中的 `EdgeSwipeFrameLayout` 负责边缘手势，不要退回会遮挡页面的悬浮 UI。

## Android 证书兼容性结论

部分设备（已在 OnePlus PKX110 上复现）直接使用 `AndroidKeyStore` 中硬件 EC 私钥进行 TLS 客户端认证会失败：服务端已选择正确证书后，手机仍会主动 EOF 断开；把签发证书导回同一个硬件密钥也无效。

现行方案不得随意回退：

1. 注册请求使用 `credential_delivery=pkcs12`。
2. 服务端生成 PKCS#12 客户端凭据。
3. Android 使用 AndroidKeyStore 中的 AES-GCM 密钥加密保存该软件凭据。
4. 注册证明密钥仍负责签署注册请求；实际 mTLS 使用加密保存的软件客户端凭据。

撤销设备证书前必须核对指纹，只撤销确认不再需要的旧证书，不要误撤销当前在用证书。

设备审批时，`agent-remote-enroll approve CODE` 会把完整 PKCS#12 打印到标准输出。这是敏感数据。审批必须把输出重定向到 root 可读临时文件或 `/dev/null`，随后用脱敏的 `agent-remote-enroll list` 核验。不得把审批输出复制到对话。

推荐流程：

```bash
agent-remote-enroll list
umask 077
agent-remote-enroll approve '<精确注册码>' >/root/.agent-remote-approve.tmp
agent-remote-enroll list
rm -f /root/.agent-remote-approve.tmp
```

批准前必须核对设备名、`pkcs12` 交付方式、创建时间和请求 ID。不能盲批未知请求。

## Windows 终端闪烁故障：不得回归

已确认的根因不是 Go 子进程本身。旧链路中，云端每次状态请求都会通过 SSH 调用 Windows：

```text
sshd.exe -> cmd.exe /c agent-remote-control.exe -> conhost.exe -> OpenConsole.exe/WindowsTerminal.exe
```

约每 7 秒生成一次控制台窗口，造成终端持续闪现。即使 Go 程序使用 `-H=windowsgui` 并给子进程设置 `CREATE_NO_WINDOW`，控制台也已经被 Windows sshd 提前创建，因此无效。

最终修复：

- `windows-control/main.go` 在现有 `127.0.0.1:58627` 监听器上提供精确路径 `POST /__local_agent_control`。
- `server/status_server.py` 通过反向隧道向 `http://127.0.0.1:58628/__local_agent_control` 发 JSON 请求。
- Caddy 公网入口显式阻断该路径。
- SSH 只保留给维护，不再承载轮询。

严禁把 `status_server.py` 改回“每个请求执行一次 SSH 命令”。如果再次出现终端闪窗，先高频采样 `sshd.exe`、`cmd.exe`、`conhost.exe`、`OpenConsole.exe` 和 `WindowsTerminal.exe` 的父子进程关系，不要只猜计划任务。

修复验证方法：云端连续多次目录请求全部成功，Windows 同期采样结果为 `NO_FLASH_PROCESSES`。

## 日常只读巡检

先检查 Windows：

```powershell
Get-ScheduledTask -TaskName 'AgentRemote-*' | Select-Object TaskName, State
Get-NetTCPConnection -State Listen -LocalAddress 127.0.0.1 -LocalPort 58626,58627,58632
Get-ChildItem "$env:LOCALAPPDATA\AgentRemote\logs" | Sort-Object LastWriteTime -Descending | Select-Object -First 10
```

再检查云端：

```powershell
ssh <服务器> "systemctl is-active caddy kimi-gateway-status kimi-enrollment"
ssh <服务器> "journalctl -u caddy --since '10 minutes ago' --no-pager | tail -n 200"
ssh <服务器> "journalctl -u kimi-gateway-status --since '10 minutes ago' --no-pager | tail -n 200"
ssh <服务器> "journalctl -u kimi-enrollment --since '10 minutes ago' --no-pager | tail -n 200"
```

从云端内网检查应用目录，令牌只在远端 shell 内读取，不带回本机：

```powershell
ssh <服务器> 'token=$(cat /etc/kimi-gateway/control-token); curl -fsS -H "Authorization: Bearer $token" http://127.0.0.1:58629/__agent_remote/apps'
```

正常状态应满足：

- 三个云端服务都是 `active`。
- 三个 Windows 计划任务都是 `Running`。
- Windows 的 `58626`、`58627`、`58632` 正在监听。
- 应用接口返回 `computer_connected: true`，被控应用返回 `running: true` 和 `code: ready`。
- 手机进入应用后没有周期性终端闪窗。

## 构建与验证

Android：

```powershell
Set-Location android
pwsh -NoProfile -ExecutionPolicy Bypass -File .\build-release.ps1
$env:JAVA_HOME='C:\Program Files\Java\jdk-23'
.\gradlew.bat --no-daemon --console=plain :app:lintRelease
```

产物位置：

`android\app\build\outputs\apk\release\app-release.apk`

Windows 控制程序：

```powershell
Set-Location windows-control
gofmt -w main.go main_test.go
go test ./...
go vet ./...
go build -trimpath -ldflags '-s -w -H=windowsgui' -o agent-remote-control.exe .
```

`-H=windowsgui` 不得删除，否则本地服务本身可能出现控制台窗口。

Python 文件用不产生字节码的方式做语法检查：

```powershell
python -c "compile(open(r'server/status_server.py',encoding='utf-8').read(),r'server/status_server.py','exec')"
python -c "compile(open(r'server/enrollment_server.py',encoding='utf-8').read(),r'server/enrollment_server.py','exec')"
```

## 上线顺序

任何上线都先做本地验证和备份，修改范围保持最小。

1. Go：执行 `gofmt`、`go test`、`go vet`，再按 Windows GUI 子系统构建。
2. Python：先 `compile(...)` 语法检查。
3. Caddy：把候选配置传到临时路径，先执行 `caddy validate --config <临时配置>`。
4. 如果修改本地控制协议，先部署 Windows 控制程序；必要时临时停止云端状态服务，避免旧服务持续产生噪声。
5. 再部署 `status_server.py` 和 Caddy 配置。
6. reload Caddy，restart 状态服务；注册服务只有在对应源码变更时才重启。
7. 检查服务、端口、应用目录、应用页面和 Windows 进程闪烁情况。
8. 最后覆盖安装 APK，保留应用数据，实机验证目录、启动/停止、进入、边缘菜单和返回目录。

注意：仓库中的 `server/Caddyfile` 是带占位符的模板，不能直接覆盖 `/etc/caddy/Caddyfile`。必须通过安装脚本完成替换，或明确替换所有占位符后再验证。

## 故障定位顺序

### 手机显示“目录暂时不可用”或 TLS I/O 错误

1. 看 Caddy 访问日志，确认请求是否到达，以及握手在哪一侧终止。
2. 看 `kimi-enrollment`，确认当前证书是否批准并进入信任集合。
3. 核对客户端是否使用 PKCS#12 交付方案，不能只看证书是否已签发。
4. 检查客户端时间、证书有效期和信任链。
5. 不要先关闭 mTLS 或把接口暴露成匿名 HTTP。

### 显示电脑未连接

1. 检查 `AgentRemote-Tunnel` 和云端 `127.0.0.1:58628`。
2. 检查 Windows `58627` 是否监听。
3. 检查云端状态服务日志是否为超时、拒绝连接或 `401/403`。
4. 核对两端控制令牌是否一致，但不要打印令牌本身；使用哈希对比。

### 显示应用未打开

1. 检查 Windows 上被控应用的监听端口（默认 `58632`）。
2. 检查 `AgentRemote-Apps` 和本地日志。
3. 通过目录接口执行 start，再检查状态；不要先改云端代理规则。

### 终端再次闪烁

1. 确认 `status_server.py` 没有调用 SSH 执行每次状态请求。
2. 对照进程父子链定位是谁创建 console host。
3. 确认 `AgentRemote-Apps` 直接运行 GUI 子系统控制程序。
4. 确认隧道和 sshd 仍通过隐藏 VBS 启动。
5. 修复后在云端连续请求接口，同时在 Windows 高频采样相关进程，不能只凭肉眼判断。

## 关键源码

- Android 客户端：`android/`
- iOS 客户端：`ios/`
- Windows 控制服务：`windows-control/main.go`、`windows-control/main_test.go`
- Windows 安装和任务脚本：`windows/install.ps1`、`windows/register-*.ps1`、`windows/unregister-*.ps1`
- 云端状态服务：`server/status_server.py`
- 云端注册服务：`server/enrollment_server.py`
- 注册管理命令：`server/kimi-enroll`
- Caddy 模板：`server/Caddyfile`
- 云端安装脚本：`server/install_gateway.sh`
- 客户端配置脚本：`configure-clients.ps1`

`configure-clients.ps1` 会从受保护的配置包写入 Android/iOS 配置。不要为了调试把替换后的令牌、证书或私钥提交进源码，也不要在命令输出中展示它们。

## 接手原则

1. 先跑只读巡检，确认真实现状，再修改。
2. 保留现有证书、令牌、注册请求、客户端应用数据和 Windows 状态目录。
3. 不因排障而降低 mTLS、Bearer、本地令牌或公网路径阻断。
4. 不回退硬件密钥兼容性问题的 PKCS#12 方案。
5. 不让状态轮询重新经过 Windows SSH。
6. 不恢复远程页悬浮 UI。
7. 每次交付都验证构建、服务、端口、真实接口、实机 TLS 和终端不闪烁。
8. 若线上状态与本文不同，以只读检查得到的现状为准，先记录差异，再做最小修复；不要盲目重装整套环境。

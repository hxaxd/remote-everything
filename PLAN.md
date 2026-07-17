# Agent Remote 交付计划与路线图

> 评审日期：2026-07-17。总目标：**开源交付**——代码可公开、他人可复现部署。
> 架构基线不变：单云服务器 ↔ 单 Windows 主机 ↔ Android 客户端；iOS 冻结；鸿蒙原生放弃。
> 原则：不盲目开发，每一步都有明确的运行与验证方法。

## 0. 已确认的决策

| 事项 | 决策 |
|---|---|
| 交付形态 | 开源；多租户运营化是未来方向，本次不做 |
| 仓库 | `agent-remote`，GitHub 私有先行 |
| 发布时机 | **不着急转公开**：先把该改的都改完（M2/M2.5/M3），攒一个超级大版本后再发布 |
| 工程原则 | 全链路 Agent 可执行、安装卸载干净可追踪、风险操作先提醒、网络环境零污染（细则见 AGENTS.md） |
| 干净化 | 自研代码全部收敛为 Go 单程序：云端三件套合并（见 M2.5 批次 1），Windows 已是；Caddy 保留作 TLS/ACME 边缘 |
| 部署形态 | 云服务器（方案 A）+ LAN 直连（方案 B，只假设局域网已存在，见 M2.5）；网络打通方案全部搁置（见第 7 节） |
| License | Apache-2.0 |
| 包名 | 已改为 `com.agentremote.app`（中性名；宣传口径以后可灵活变化，不影响包名） |
| 现有 token/引导证书 | 暂不轮换（知情接受其曾进入 AI 会话日志的风险；如目录外发过再轮换） |
| p12 密码生命周期 | 视为 bug，**已修复**（见 2.1） |
| 58630 SSH 控制通道 | **保留**——AGENTS.md 定为维护/兜底通道；轮询改走 HTTP 是因为终端闪烁事故，不是死代码 |
| enrollment `certificate` 投递模式 | 真死代码，随 Go 网关重写自然消亡（不再移植） |
| Android 备份 | manifest 已是 `allowBackup="false"`，换机即重新注册；孤儿备份规则 xml 已删 |
| `/open` 与状态页鉴权 | 不改代码，文档写明设计意图（mTLS 之内不鉴权是有意设计） |
| 健壮性/日志 | 全做，日志尽可能全（M2） |
| CI、Android 发版、文档补全、冻结 iOS | 全做（M3）；冻结期间 iOS 源码仅做脱敏和包名同步 |

## 1. 测试基线（每一步都引用这里）

- **本地静态检查**：`python -c "compile(...)"` 语法检查（不产生字节码）、`gofmt -w && go vet && go test`（windows-control 与 server/gateway）、`android/gradlew.bat :app:assembleDebug`
- **服务端全链路测试**（部署后在服务器上跑，覆盖：注册→审批→密码擦除断言→mTLS→应用目录→路由→启停→吊销）：
  ```powershell
  scp .\server\test_enrollment_pkcs12.py "root@服务器:/tmp/t.py"
  ssh "root@服务器" "PUBLIC_HOST='服务器' python3 /tmp/t.py"
  ```
- **Windows 侧验证**：重跑 `windows/install.ps1` 确认幂等；`Get-ScheduledTask 'AgentRemote-*'`；端口 58626/58627/58632 监听检查（README 第 3 节）
- **Android 真机冒烟**：安装→注册→审批→目录刷新→进入→启停→边缘侧滑菜单→返回
- **安全自查**：`git grep -E '[0-9a-f]{64}'`、`git grep <服务器IP>` 必须无命中；`git ls-files` 不含 p12/properties/local.properties

## 2. 里程碑 M1：安全出库（开源前置）

### 2.1 p12 密码生命周期 ✅ 已完成

- `server/kimi-enroll`：审批生成 p12 后立即 `pop("credential_password")`，密码不再落盘留存。
- `server/enrollment_server.py`：每小时清理过期 pending 请求；`find_existing` 跳过已过期 pending，重注册不再被旧请求卡死。
- `server/test_enrollment_pkcs12.py`：断言审批后状态文件不含 `credential_password`。
- **部署动作（待做）**：随 M2.5 批次 1 的 Go 网关一起上线（届时跑全链路测试复验）。

### 2.2 git 化与密钥出库 ✅ 已完成

- Android 配置改 BuildConfig：真实值存于被 gitignore 的 `android/agent-remote.properties`（由 `configure-clients.ps1` 生成），`AppConfig.kt` 只读 `BuildConfig`，仓库零密钥。
- iOS `AppConfig.swift` 改占位符（iOS 冻结，仅脱敏）。
- 包名 `com.hxaxd.agentremote` → `com.agentremote.app`（Android package/applicationId、iOS bundleId；iOS keychain tag 是存储键，保持不变）。
- 个人痕迹清理：`status_server.py` 死函数 `load_config`（含 hxaxd 默认值）已删；`build-release.ps1` 证书 DN 去 HXAXD；测试脚本 IP 默认值改为必须显式传 `PUBLIC_HOST`。
- `AGENTS.md` 按最佳实践重写为规则集（2026-07-17 再修订），原文存 `AGENTS.local.md`（gitignore，仅本地）。
- 首次提交已推送 GitHub 私有仓库。

## 2.5 里程碑 M2.5：Go 统一 + LAN 直连

两条设计决策（2026-07-17 定）：

- **干净化**：自研代码全部收敛为 Go 单程序。云端：`enrollment_server.py` + `status_server.py` + `kimi-enroll` 合并为一个 Go 二进制（`server/gateway/`），替代 Python；Caddy 保留作 TLS/ACME 边缘（Go 系 ACME 客户端不支持裸 IP 证书，Caddy 的 shortlived profile 是刚需）。Windows：维持 Go 单程序。
- **直连模式只假设局域网已存在**。网络如何打通一概不做（见第 7 节）。

### 批次 1 —— 云端 Go 网关（协议逐字节兼容，手机端无感）

> **状态（2026-07-17）**：实现完成（`server/gateway/` 单二进制三角色：enrollment-server/status-server/enroll，纯 encoding/json），本地 gofmt/vet/test/交叉编译全绿；部署胶合层就绪（`build_gateway.ps1`、`install_gateway.sh`、systemd 单元、Caddyfile 关 80）；**待部署上线验证**。按「未发布无兼容包袱」定调已清除：pyjson 兼容层、Python 三件套（仓库侧）、certificate 投递模式、Python 差分测试。

1. `server/gateway/`：单 Go 模块，子命令 `enrollment-server`（58631）、`status-server`（58629）、`enroll list|approve|revoke|rebuild`；状态文件格式、`approved-clients`、trust 重建（`caddy validate` + reload）与现状完全一致。
2. 内建结构化日志与审计（approve/revoke 记录审批码与指纹），替代 M2 原定的 Python 日志项。
3. PKCS#12 编码用 `software.sslmate.com/src/go-pkcs12`（Go 标准库没有 p12 编码）。
4. 交叉编译 `GOOS=linux` 随 `server/` 一起 scp，服务器不装 Go 工具链；`install_gateway.sh` 改为安装二进制 + systemd 单元。
5. 服务器端口纪律：ACME 改 `tls-alpn-01`，Caddy 关闭 80 监听与重定向，服务器只开 443+22。
6. `certificate` 投递模式不移植，随重写自然消亡。
7. 验证：本地 `go test`（含 p12 与 Python cryptography 互解兼容用例）→ 部署 → 全链路测试 + 真机冒烟 → 稳定后删除 Python 三件套。

### 批次 2 —— LAN 直连（批次 1 稳定后再动）

1. 同一个 gateway 二进制跑在 Windows 上，TLS 层内嵌（`ClientAuth: RequireAndVerifyClientCert`），服务器证书安装时自签；不装 Caddy/Python，对外只开一个可配置高端口。
2. Android 服务器证书固定（SPKI SHA-256 pin，`configure-clients.ps1` 从 bundle 写入 properties；`SecureHttp` pinning TrustManager；WebView 指纹匹配才 proceed，保留主机名校验）——最需要写对的点，pin 错=锁死或降安全。
3. 直连模式控制通道内化为本机调用（gateway 直接调 `127.0.0.1:58627`），SSH 隧道层不需要。
4. `configure-clients.ps1` 支持直连模式；README 写两种部署形态对比。
5. 验证：LAN 真机全链路（注册→审批→进入→启停）；云端模式回归测试。

## 3. 里程碑 M2：健壮性与可运维

### 3.1 Go 监管补强（`windows-control/main.go`）

- supervise 加重启退避（崩溃后 2s→最长 5min 指数退避，稳定运行后重置）；应用日志按大小轮转（单代 `.log.old`，上限 4MB）。
- `stopApp` 4 秒超时后返回 `stopping` 中间态而非直接报当前态。
- 验证：`go test` 新增退避/轮转用例；注册一个立即崩溃的假应用，观察重启间隔与日志体积。

### 3.2 日志与审计（尽可能全）

- 服务端日志/审计并入 M2.5 批次 1 的 Go 网关内建（请求路径、结果码、request_id 脱敏前缀；approve/revoke 记录时间、审批码、指纹）。
- Windows Go 服务记录控制动作（list/start/stop 结果）到 `logs/control.log`（同 3.1 轮转）。
- 验证：`journalctl` 看到请求流水；审批/吊销各一次查审计；手机端启停一次查 control.log。

### 3.3 Android 修补

- 注册状态轮询收到 404 时自动重新发起注册（配合 2.1 的过期清理；当前只会无限轮询）。
- 目录状态新增 `stopping` 文案映射（配合 3.1 的停止中间态）。
- 验证：构建通过；真机走一遍「注册→审批」；过期场景手工把服务器上请求文件删除后观察客户端自愈。

## 4. 里程碑 M3：工程化与开源

### 4.1 CI（GitHub Actions）

- Job：`go test`（windows-control + server/gateway）；`gradlew assembleDebug`（CI 里生成 dummy `agent-remote.properties`）；shellcheck（server/*.sh）；密钥扫描（grep 64-hex / 私钥头，命中即失败）。
- 验证：提 PR 触发，全绿才合并。

### 4.2 Android 发版

- 开 R8（`isMinifyEnabled = true`，纯手写 View 无反射，风险低，先跑真机冒烟确认）。
- 签名密钥离线备份写进文档（密钥丢失=用户必须卸载重装）。
- versionCode/versionName bump 规则写进 CONTRIBUTING。

### 4.3 文档与开源清单

- 文档：README 修订、UNINSTALL（完整卸载：计划任务/状态目录/服务端）、TROUBLESHOOTING（隧道掉了先查 `logs/tunnel.log` 与计划任务）、SECURITY（威胁模型：服务器 root 可冒充已审批设备、control-token 烧进 APK、人工审批是安全边界、`/open` 与状态页在 mTLS 内不鉴权是有意设计、现有凭证未轮换的风险声明）、UPGRADING（各组件升级步骤与断线影响）。
- 清单：CONTRIBUTING、issue 模板（可选）。
- **转公开前置检查**：全仓库 grep 密钥/IP/个人路径；CI 全绿；文档齐；然后仓库 flip public。

## 5. 未来路线图（评估结论，均不在本次交付范围）

| 事项 | 评估 | 前置依赖 | 建议批次 |
|---|---|---|---|
| 接入酒馆 SillyTavern（第二个应用） | 已定位：`~/learn/SillyTavern`（官方 git 已更新，冒烟 HTTP 200）；Web 服务监听 18000；Node 经 fnm 提供（无系统 PATH，用绝对路径）；`workdir` 支持已加入 windows-control 与 register-app.ps1 | 待定：`listen: true→false` 收口、应用层鉴权方式 | 交付后第一批，顺便验证插件化 |
| Kimi Code/酒馆原生体验优化 | WebView 层可做 viewport/缩放/键盘/UA；深度受酒馆 Web 端可改性限制 | 酒馆接入完成 | 第二批 |
| 运维/二开 skill 化 + 应用插件化 | 完全可行：SKILL.md 封装部署/加应用/审批/排障；插件化=应用清单 JSON 模板+校验+文档 | 无 | M3 期间同步做（开源加分项） |
| UI 重做（图标/改名/审批白屏） | 白屏是 bug：`showEnrollment`/`showStartupFailure`/`showRemoteFailure` 的 ScrollView 无背景且未 fillViewport（`MainActivity.kt` 三处）；图标与命名需设计决策 | 命名/图标方向 | 交付后第一批 |
| 方向锁定 + 应用级设置 | 可行：`requestedOrientation` + 按 app id 存 SharedPreferences；目录与远程菜单各加设置入口，应用级覆盖全局 | 无 | 与 UI 重做同批 |
| 自定义悬浮快捷键 | 可行：应用内 overlay（无需系统悬浮窗权限），拖动定位/手势缩放/按应用持久化；**需先定义动作集**（JS 注入 vs 按键事件），先做 2-3 个固定动作验证链路再开放自由配置 | 动作集定义 | 第三批 |
| 卓易通兼容 | 报错根因基本可定为容器内 AndroidKeyStore 不可用；方案：软件密钥回退 + 明确降级提示；**最大未知：卓易通 WebView 是否支持客户端证书挑战** | 真机探针：①keygen 是否抛异常 ②WebView mTLS 握手是否走 `onReceivedClientCertRequest` | 独立里程碑，探针先行；需在 SECURITY.md 声明该平台密钥非硬件绑定 |

## 6. 待用户决策（不阻塞 M1/M2）

1. 应用新显示名与图标方向（UI 重做前置；宣传口径可蹭热点，包名不变）。
2. 酒馆接入的两个决策：`config.yaml` 的 `listen: true` 是否收口为 `false`（当前无应用层鉴权，局域网可达 18000）；鉴权用 SillyTavern basicAuth 还是依赖 mTLS 不加。
3. 悬浮快捷键首批动作集（如 Esc、Ctrl+C、粘贴）。
4. README/文档语言：纯中文还是中英双语。

## 7. 明确不做

- 网络打通方案一律搁置不采用：IPv6 直连、Tailscale/ZeroTier overlay（与翻墙代理抢单 VPN 槽）、frp 等 TCP 中转、复用翻墙 VPS；直连模式只假设局域网已存在（2026-07-17 定）。
- 不用 Go 替换 Caddy：Go 系 ACME 客户端不支持裸 IP 证书（Let's Encrypt shortlived profile 是刚需），Caddy 保留作 TLS/ACME 边缘。
- 多租户运营化（未来升级方向，架构改动另立项）。
- iOS 客户端功能性改动（冻结；仅随 M1 做脱敏与包名同步）。
- 鸿蒙原生（已放弃，不再尝试；卓易通走 Android 容器兼容路线）。
- 轮换现有凭证（用户决策，知情接受风险；SECURITY.md 中声明）。

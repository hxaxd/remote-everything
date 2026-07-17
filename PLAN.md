# Agent Remote 交付计划与路线图

> 评审日期：2026-07-17。总目标：**开源交付**——代码可公开、他人可复现部署。
> 架构基线不变：单云服务器 ↔ 单 Windows 主机 ↔ Android 客户端；iOS 冻结；鸿蒙原生放弃。
> 原则：不盲目开发，每一步都有明确的运行与验证方法。

## 0. 已确认的决策

| 事项 | 决策 |
|---|---|
| 交付形态 | 开源；多租户运营化是未来方向，本次不做 |
| 仓库 | `agent-remote`，GitHub 私有先行，M3 打磨完转公开 |
| License | Apache-2.0 |
| 包名 | 已改为 `com.agentremote.app`（中性名；宣传口径以后可灵活变化，不影响包名） |
| 现有 token/引导证书 | 暂不轮换（知情接受其曾进入 AI 会话日志的风险；如目录外发过再轮换） |
| p12 密码生命周期 | 视为 bug，**已修复**（见 2.1） |
| 58630 SSH 控制通道 | **保留**——AGENTS.md 定为维护/兜底通道；轮询改走 HTTP 是因为终端闪烁事故，不是死代码 |
| enrollment `certificate` 投递模式 | 真死代码，作为 M1 可选小项删除 |
| Android 备份 | manifest 已是 `allowBackup="false"`，换机即重新注册；孤儿备份规则 xml 已删 |
| `/open` 与状态页鉴权 | 不改代码，文档写明设计意图（mTLS 之内不鉴权是有意设计） |
| 健壮性/日志 | 全做，日志尽可能全（M2） |
| CI、Android 发版、文档补全、冻结 iOS | 全做（M3）；冻结期间 iOS 源码仅做脱敏和包名同步 |

## 1. 测试基线（每一步都引用这里）

- **本地静态检查**：`python -c "compile(...)"` 语法检查（不产生字节码）、`gofmt -w && go vet && go test ./windows-control`、`android/gradlew.bat :app:assembleDebug`
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
- **部署动作（待做）**：三个文件同步到服务器并 `systemctl restart kimi-enrollment`，然后跑全链路测试复验。

### 2.2 git 化与密钥出库 ✅ 已完成

- Android 配置改 BuildConfig：真实值存于被 gitignore 的 `android/agent-remote.properties`（由 `configure-clients.ps1` 生成），`AppConfig.kt` 只读 `BuildConfig`，仓库零密钥。
- iOS `AppConfig.swift` 改占位符（iOS 冻结，仅脱敏）。
- 包名 `com.hxaxd.agentremote` → `com.agentremote.app`（Android package/applicationId、iOS bundleId；iOS keychain tag 是存储键，保持不变）。
- 个人痕迹清理：`status_server.py` 死函数 `load_config`（含 hxaxd 默认值）已删；`build-release.ps1` 证书 DN 去 HXAXD；测试脚本 IP 默认值改为必须显式传 `PUBLIC_HOST`。
- `AGENTS.md` 脱敏入库，原文存 `AGENTS.local.md`（gitignore，仅本地）。
- 首次提交已推送 GitHub 私有仓库。

### 2.3 剩余小项（可选）

- 删 enrollment 的 `certificate` 投递模式（`enrollment_server.py`、`kimi-enroll` 对应分支）。
- 验证：全链路测试。

## 3. 里程碑 M2：健壮性与可运维

### 3.1 Go 监管补强（`windows-control/main.go`）

- supervise 加重启退避（崩溃后 2s→最长 5min 指数退避，稳定运行后重置）；日志按大小截断/轮转（每应用单独文件，上限如 4MB）。
- `stopApp` 4 秒超时后返回 `stopping` 中间态而非直接报当前态。
- 验证：`go test` 新增退避/轮转用例；注册一个立即崩溃的假应用，观察重启间隔与日志体积。

### 3.2 日志与审计（尽可能全）

- 服务端两个 Python 服务输出结构化日志到 stdout（systemd 接管，含请求路径、结果码、request_id 脱敏前缀）；`kimi-enroll` 的 approve/revoke 记录时间、审批码、指纹。
- Windows Go 服务记录控制动作（list/start/stop 结果）到 `logs/control.log`（同样轮转）。
- 验证：`journalctl -u kimi-enrollment -u kimi-gateway-status` 看到请求流水；审批/吊销各一次查审计；手机端启停一次查 control.log。

### 3.3 Android 修补

- 注册状态轮询收到 404 时自动重新发起注册（配合 2.1 的过期清理；当前只会无限轮询）。
- 验证：构建通过；真机走一遍「注册→审批」；过期场景手工把服务器上请求文件删除后观察客户端自愈。

## 4. 里程碑 M3：工程化与开源

### 4.1 CI（GitHub Actions）

- Job：`go test`；`py_compile` + enrollment 逻辑单测（把冒烟固化）；`gradlew assembleDebug`（CI 里生成 dummy `agent-remote.properties`）；shellcheck（server/*.sh）；密钥扫描（grep 64-hex / 私钥头，命中即失败）。
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
| 接入酒管（第二个应用） | 架构原生支持，`register-app.ps1` 即为此设计；**前提：酒管有监听 127.0.0.1 的 Web 服务**，没有则需适配层 | 确认酒管形态 | 交付后第一批，顺便验证插件化 |
| Kimi Code/酒管原生体验优化 | WebView 层可做 viewport/缩放/键盘/UA；深度受酒管 Web 端可改性限制 | 酒管接入完成 | 第二批 |
| 运维/二开 skill 化 + 应用插件化 | 完全可行：SKILL.md 封装部署/加应用/审批/排障；插件化=应用清单 JSON 模板+校验+文档 | 无 | M3 期间同步做（开源加分项） |
| UI 重做（图标/改名/审批白屏） | 白屏是 bug：`showEnrollment`/`showStartupFailure`/`showRemoteFailure` 的 ScrollView 无背景且未 fillViewport（`MainActivity.kt` 三处）；图标与命名需设计决策 | 命名/图标方向 | 交付后第一批 |
| 方向锁定 + 应用级设置 | 可行：`requestedOrientation` + 按 app id 存 SharedPreferences；目录与远程菜单各加设置入口，应用级覆盖全局 | 无 | 与 UI 重做同批 |
| 自定义悬浮快捷键 | 可行：应用内 overlay（无需系统悬浮窗权限），拖动定位/手势缩放/按应用持久化；**需先定义动作集**（JS 注入 vs 按键事件），先做 2-3 个固定动作验证链路再开放自由配置 | 动作集定义 | 第三批 |
| 卓易通兼容 | 报错根因基本可定为容器内 AndroidKeyStore 不可用；方案：软件密钥回退 + 明确降级提示；**最大未知：卓易通 WebView 是否支持客户端证书挑战** | 真机探针：①keygen 是否抛异常 ②WebView mTLS 握手是否走 `onReceivedClientCertRequest` | 独立里程碑，探针先行；需在 SECURITY.md 声明该平台密钥非硬件绑定 |

## 6. 待用户决策（不阻塞 M1/M2）

1. 应用新显示名与图标方向（UI 重做前置；宣传口径可蹭热点，包名不变）。
2. 酒管有无 Web 服务、能否指定监听地址端口（酒管接入前置）。
3. 悬浮快捷键首批动作集（如 Esc、Ctrl+C、粘贴）。
4. README/文档语言：纯中文还是中英双语。

## 7. 明确不做

- 多租户运营化（未来升级方向，架构改动另立项）。
- iOS 客户端功能性改动（冻结；仅随 M1 做脱敏与包名同步）。
- 鸿蒙原生（已放弃，不再尝试；卓易通走 Android 容器兼容路线）。
- 轮换现有凭证（用户决策，知情接受风险；SECURITY.md 中声明）。

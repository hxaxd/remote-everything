# AGENTS.md — Agent 工作规则

一句话：Android 手机经 mTLS 网关远程控制 Windows 上的本地 Web 应用（默认 Kimi Code）。

文档地图：`README.md` = 从零复现部署；`PLAN.md` = 交付计划与路线图；`AGENTS.local.md`（gitignore，不入库）= 本实例的服务器地址、指纹、巡检命令等。

## 构建与验证

- Python 语法检查（不产生字节码）：
  `python -c "compile(open(r'server/test_enrollment_pkcs12.py',encoding='utf-8').read(),r'x','exec')"`
- Go：`cd windows-control && gofmt -w main.go main_test.go && go vet ./... && go test ./...`；`server/gateway` 同法（另有 `pwsh server/build_gateway.ps1` 交叉编译 linux 产物）
- Android：`cd android && gradlew.bat :app:assembleDebug`（需先跑 `configure-clients.ps1` 生成 `agent-remote.properties`）
- 改动 `server/` 后必跑服务端全链路测试：见 `PLAN.md` 第 1 节
- 上线顺序、巡检与故障定位：见 `AGENTS.local.md`

## 硬性安全规则（违反 = 返工）

- 密钥、令牌、PKCS#12、注册口令、真实配置：不进源码、不进提交、不进对话与日志。Android 连接参数只走被 gitignore 的 `android/agent-remote.properties`（BuildConfig 注入）。
- 不降低任何一层防护：公网 mTLS、Bearer 令牌、`/__local_agent_control` 的公网 403、本地令牌的常量时间比较。
- `agent-remote-enroll approve` 的输出含完整 p12：必须重定向到 root 临时文件或 `/dev/null`，核验只用脱敏的 `list`。
- 审批前核对设备名、交付方式、创建时间、请求 ID，不盲批未知请求。

## 事故教训（不得回归）

1. **终端闪烁**：状态轮询严禁走 Windows SSH（`sshd→cmd→conhost` 约每 7 秒弹一次窗）。控制必须走反向隧道上的 HTTP `POST /__local_agent_control`。再遇闪窗，先高频采样 `sshd.exe`/`cmd.exe`/`conhost.exe`/`OpenConsole.exe`/`WindowsTerminal.exe` 的父子进程链，不要只猜计划任务。
2. **硬件密钥失败**：部分设备（OnePlus PKX110 已复现）用 AndroidKeyStore 硬件 EC 私钥做 TLS 客户端认证会在握手时主动 EOF，导回证书也无效。现行「服务端生成 p12 软件凭据 + AndroidKeyStore AES-GCM 包裹保存」方案不得回退。
3. `-H=windowsgui` 不得从 Go 构建参数中删除（否则本地服务自己会弹窗）。
4. 不恢复远程页的悬浮 UI；边缘手势走 `EdgeSwipeFrameLayout`。
5. 升级客户端只能同包名同签名覆盖安装，禁止卸载（本机凭据会丢）。

## 约定

- **全链路 Agent 可执行**：所有安装与配置操作必须能由 Agent 非交互完成（脚本幂等、参数化、可重跑），目标是完全不懂技术的用户也能从容部署；风险操作前只需向用户说明。
- **安装卸载干净可追踪**：不装多余组件，改动可枚举，卸载能完整还原（计划任务、状态目录、端口、文件全部可回收）。
- **网络环境零污染**：对外只占用必要的高端口（每个部署形态一个对外端口）；不占用 80/443 等公共端口（服务器侧除外：仅 443+22）；Caddy 之类的大件不进 Windows。
- 说明文档集中在本文件、`README.md`、`PLAN.md` 与 `docs/`（交付文档）；源码不堆解释性注释。
- 鸿蒙相关一切不引入（用户明令，除非本人反悔）；新应用接入须用户明确要求。
- 用户偏好命令行，未经要求不操作桌面 UI。
- git 禁用破坏性命令（`reset --hard`、`checkout --`、`push --force`）。
- `server/Caddyfile` 是占位符模板，替换占位符并 `caddy validate` 通过前不得上线。

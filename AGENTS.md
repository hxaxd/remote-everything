# AGENTS.md — Agent 工作规则

一句话：Android 通用客户端经局域网入口或公网 mTLS 网关，远程控制 Windows、Linux 或 macOS 节点上明确注册的本地 Web 应用。

总原则：**我们的项目不需要人类去阅读，只需要 Agent 去阅读就可以了。** 文档、目录和脚本优先保证 Agent 可发现、可执行、可验证，不为人类阅读习惯保留重复入口或兼容层。

## 当前阶段最高优先级：严格收窄范围

**只修改用户本次明确点名的分区和范围。判断完成的标准是该分区对外暴露的接口与语义稳定，不是顺手把外围工程一起“完善”。不得以一致性、将来会需要、方便发布或最佳实践为理由，主动扩散修改。**

当前固定顺序是：节点 → 服务端 → 客户端 → skills → 2.0 正式开源。用户目前推进到哪个分区，就只处理哪个分区；后续分区即使发现问题，也只记录，不提前修改。文档整理、skills 调整、CI/CD、构建产物上传、发布流程和开源收尾，统一留到用户推进到对应阶段，除非用户在当前请求中逐项明确点名。

执行方式是一对一：用户要求多大范围就做多大范围。完成必要代码和直接测试后立即停止，不自行追加跨分区重构、文档同步、流水线接入、产物发布或上传。

目录地图：`clients/android/` = Android 客户端；`nodes/windows/`、`nodes/linux/`、`nodes/macos/` = 三平台节点；各节点的测试统一放在自身 `tests/`；`server/lan/` = 三平台局域网服务；`server/public/` = Linux 公网服务；`skills/` = 标准操作流程与执行参考；`.github/` = 仓库自动化。`README.md` = Agent 入口索引；`AGENTS.local.md`（gitignore，不入库）= 本实例信息；`PLAN.md`（gitignore，不入库）= 交付计划。

应用认知：节点启动后允许没有任何应用；项目不定义、不预装、不隐式选择默认应用。用户提出接入需求后，由 Agent 按 `remote-everything-app` skill 调用节点核心的 `app set/list/remove` 原子命令并验证。

节点职责：三平台节点只维护明确注册的应用进程与本地探活端口，在初始化持久化的 loopback 地址提供应用目录、启停控制和反向代理。公网模式由 Agent 在项目运行目录准备并启动 FRPC；局域网模式运行 `server/lan`。节点侧组件只承诺部署用户登录期间可用：Windows 使用登录触发的用户计划任务，macOS 使用用户 LaunchAgent，Linux 使用不启用 lingering 的用户级 systemd。

网关职责：局域网入口不鉴权客户端，客户端固定其服务端证书指纹，入口用内部令牌访问节点。公网服务用短期单次邀请签发 pending 设备证书；设备持证提交申请，用户核对设备名与完整指纹后由 Agent 显式批准，设备再完成真实链路激活。后续由 mTLS 与网关设备记录共同鉴权。控制令牌只存在于网关到节点的内部链路。反向代理与 FRPS 由 Agent 按目标服务器现状接入，并记录配置与服务引用。

客户端职责：Android 只有一个通用构建。安装 Agent 生成包含入口与局域网指纹或公网单次邀请的 setup URI；手机扫描后先实际连通并鉴权，成功才提交 profile。APK 不包含内部控制令牌或部署证书。

版本认知：当前架构为 2.0，不保留任何旧状态、命令或字段兼容性。发生破坏性变化时按 `remote-everything-remove` skill 清理当前运行目录，再按当前结构搭建。

## 构建与验证

- Python 语法检查（不产生字节码）：
  `python -c "compile(open(r'server/public/tests/pairing_pkcs12.py',encoding='utf-8').read(),r'x','exec')"`
- 节点：Windows 运行 `pwsh nodes/windows/tests/run.ps1`；Linux 运行 `bash nodes/linux/tests/run.sh`；macOS 运行 `bash nodes/macos/tests/run.sh`。各平台还需运行 `gofmt -w main.go && go vet ./... && go build ./...`。
- 局域网服务支持三平台：运行 `cd server/lan && gofmt -w . && go vet ./... && go test ./... && go build ./...`。
- 公网服务仅支持 Linux：在 Linux 运行 `cd server/public && gofmt -w . && go vet ./... && go test ./...`；其他平台只交叉编译检查 `GOOS=linux go build ./...`。
- Android：`cd clients/android && gradlew.bat :app:testDebugUnitTest :app:lintDebug :app:assembleDebug`；构建不读取部署配置或凭据。
- 改动公网服务后按可用环境运行 `server/public/tests/pairing_pkcs12.py` 全链路测试。
- 上线顺序、巡检与故障定位：见 `AGENTS.local.md`

## 事故教训（不得回归）

1. **终端闪烁**：旧链路每次状态请求都经 Windows SSH 执行命令，`sshd→cmd→conhost` 约每 7 秒弹一次窗。教训：**任何「每次请求拉起一个控制台进程」的设计都会闪窗**——控制必须走常驻进程上的 HTTP（`POST /__local_remote_control`）。再遇闪窗，先高频采样进程父子链（历史上是 `sshd.exe`/`cmd.exe`/`conhost.exe`/`OpenConsole.exe`/`WindowsTerminal.exe`），不要只猜计划任务。Windows SSH 已整体退役（隧道层为 FRP），严禁为图省事把轮询改回「每次请求执行一次命令」。
2. **硬件密钥失败**：部分设备（OnePlus PKX110 已复现）用 AndroidKeyStore 硬件 EC 私钥做 TLS 客户端认证会在握手时主动 EOF，导回证书也无效。现行「服务端生成 p12 软件凭据 + AndroidKeyStore AES-GCM 包裹保存」方案不得回退。
3. `-H=windowsgui` 不得从 Go 构建参数中删除（否则本地服务自己会弹窗）。
4. **代理 TUN 与隧道**：用户普遍常开代理（Clash 系 TUN 模式接管全流量），frp 走高端口原始 TCP 会被代理链路卡死。隧道一律走 **wss（WebSocket over 443）**，由服务器现有反向代理把专用路径路由到 loopback 的 frps；frpc 客户端证书必须由独立的隧道 CA 签发。frpc 这类控制台程序必须经 `wscript` 隐藏启动，直起必弹窗。
5. **应用进程树**：Windows 常驻控制程序必须把自身加入带 `KILL_ON_JOB_CLOSE` 的 Job Object；Linux 必须用独立进程组与 `Pdeathsig`，生产服务再由 systemd `KillMode=control-group` 兜底；macOS 必须由随节点启动的守护子进程监控父进程，并把应用放入可整体终止的独立进程组。控制程序异常退出或服务卸载时必须回收整棵应用进程树。

## 约定

- **全链路 Agent 可执行**：安装、配置、更新和清理由 Agent 按 `skills/` 完成，并适配目标机器的现有环境。
- **运行目录可追踪**：程序、依赖、配置、状态和日志放在项目 `.runtime/`；进程、参数、端口、管理器与外部系统引用记录在 `runtime.json`。
- **依赖由 Agent 管理**：FRP 等外部程序由 Agent 获取、校验并放入 `.runtime/bin/`，项目不提供系统安装脚本。
- **远程组网由用户选择**：项目只复用用户已经选择并建立的远程组网，不推荐、不安装、不管理具体组网产品；尚无组网时由 Agent 与用户对齐后等待其建立。
- **网络环境零污染**：对外只占用必要的高端口（每个部署形态一个对外端口）；不占用 80/443 等公共端口（服务器侧除外：仅 443+22）；Caddy 之类的大件不进节点。
- 说明集中在本文件、`README.md` 与各 `SKILL.md`；源码不堆解释性注释。PR 必须 CI 全绿，安全边界只强不弱，改动保持最小。发版在 `clients/android/app/build.gradle.kts` 递增 `versionCode` 与 `versionName`。
- git 禁用破坏性命令（`reset --hard`、`checkout --`、`push --force`）。

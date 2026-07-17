# 故障排查

总原则：先只读检查确认现状，再按下面的顺序定位；不要为了排障降低 mTLS、Bearer 或本地令牌防护。

## 手机显示「目录暂时不可用」或 TLS I/O 错误

1. 看 Caddy 访问日志，确认请求是否到达、TLS 握手在哪一侧终止：`ssh <服务器> "journalctl -u caddy --since '10 minutes ago' --no-pager | tail -n 200"`。
2. 确认设备证书已批准并进入信任集合：`agent-remote-enroll list`。
3. 核对客户端用的是 PKCS#12 交付方案，不能只看证书是否已签发。
4. 检查客户端时间、证书有效期和信任链。

## 显示电脑未连接

1. 检查 Windows `AgentRemote-Tunnel` 计划任务（frpc）与云端 `127.0.0.1:58628` 是否有隧道监听；frpc 日志在 `%LOCALAPPDATA%\AgentRemote\logs\frpc.log`，frps 日志在云端 `journalctl -u frps`。
2. 检查 Windows `127.0.0.1:58627` 是否监听（`AgentRemote-Apps` 任务）。
3. 看云端状态服务日志是超时、拒绝连接还是 401/403。
4. 检查云端 `7000` 端口可达性，核对两端 frp token 一致（用哈希对比，不要打印令牌本身）。

## 显示应用未打开

1. 检查 Windows 上被控应用的监听端口（默认 `58632`）。
2. 检查 `AgentRemote-Apps` 计划任务与 `%LOCALAPPDATA%\AgentRemote\logs\<应用id>.log`、`control.log`（含启停动作与崩溃退避记录）。
3. 通过目录接口执行 start 再看状态；不要先改云端代理规则。

## Windows 终端周期性闪窗

这是已知事故的复发信号（见 AGENTS.md 事故教训 1），按序确认：

1. 确认没有服务改回「每次请求执行一次命令」——轮询必须走常驻进程上的 HTTP。
2. 高频采样可疑进程的父子链（历史上是 `sshd.exe`、`cmd.exe`、`conhost.exe`、`OpenConsole.exe`、`WindowsTerminal.exe`），定位谁创建了控制台。
3. 确认 `AgentRemote-Apps` 直接运行 GUI 子系统构建的控制程序（`-H=windowsgui`）。
4. 修复后云端连续请求接口、Windows 高频采样验证，不要只凭肉眼判断。

## 注册一直停在「等待服务端批准」

1. 核对手机显示的 8 位审批码与服务器 `agent-remote-enroll list` 里的请求一致（设备名、时间）。
2. 请求 24 小时过期；过期后服务端会清理，手机端会自动重新发起注册并显示新审批码。
3. 批准时提示「not found or ambiguous」：审批码撞码（罕见），让手机重新生成一个。

# 部署模板

`assets/` 使用 `{{NAME}}` 占位符。将初始化输出与目标系统观测值作为精确字段的 JSON，调用 `scripts/render.py KIND --input - --output TARGET`；需保存输入时将 `-` 换成文件路径。Windows 另传 `--launcher-output TARGET.vbs`。渲染器负责对应格式的转义，并拒绝未知字段、错误类型、相对路径和控制字符。

## 服务管理器

| 模板 | 适用组件与安装位置 |
| --- | --- |
| `systemd-user` | Linux 节点、本地 LAN 入口和 FRPC；部署用户的 `~/.config/systemd/user/`，用 `systemctl --user` 管理，不启用 lingering |
| `systemd` | Linux 服务器上的 gateway/FRPS；远端 LAN 隧道的 LAN/FRPS 也用系统服务；进程树以 `KillMode=control-group` 回收 |
| `caddy-systemd` | 没有既有入口时的项目 Caddy；非 root 账户，仅授予绑定低端口的 capability，数据在运行目录内 |
| `launchd` | macOS 节点、LAN 和 FRPC；用户的 `~/Library/LaunchAgents/` |
| `scheduled-task` 与隐藏 VBS 启动器 | Windows 节点、LAN 和 FRPC；用户登录触发，由 wscript 隐藏启动 |

用户会话服务仅在部署用户登录期间可用。管理器名称中的身份：node 用 `node_id`，FRPC 用所属网关 `installation_id`，入口用自身 `installation_id`；同一记录内多组件用独立组件 ID，规则见 [runtime.md](runtime.md)。

Windows 启动器拉起的进程会脱离计划任务实例；停止任务后，仍须按 runtime 的可执行路径、完整参数、PID 和启动时间匹配残留进程，再结束该组件的进程树。停止其中一条隧道不能按 `frpc.exe` 名字全机清理。

## FRP 配置

版本固定值见 [releases.md](releases.md)。两种传输均使用 wire v2、客户端 `poolCount=32` 与服务端 `maxPoolCount=32`；多设备、轮询和长连接共用池，过小会引起丢连接和重连。FRPS 的 `proxyBindAddr` 必须为 loopback，避免把节点控制面发布到公网。

| 渲染模式 | 传输及配置 |
| --- | --- |
| `frps` | public 的明文 loopback FRPS；输入 `frps_port/frps_token_file/frps_log` |
| `frpc` | public 的 WSS `/~!frp`、443、系统服务端信任与隧道客户端证书；输入见下表 |
| `frps-lan` / `frpc-lan` | 直连双向 TLS；完整字段与服务端证书维护见 [lan-tunnel.md](lan-tunnel.md) |

public FRPC 输入字段：

| 字段 | 取值 |
| --- | --- |
| `public_host` | 网关 origin 的域名 |
| `node_id` | 该节点的稳定 ID，代理名为 `node-<node_id>` |
| `node_host` / `node_port` | 该节点自身 `listen_address` 的主机与端口 |
| `node_tunnel_port` | 网关 `node add` 输出 `node_address` 的端口，或 `node list` 对应项 `address` 的端口 |
| `tunnel_client_cert` / `tunnel_client_key` / `frps_token_file` | 节点机器上交付材料的最终绝对路径 |
| `frpc_log` | 该隧道的日志绝对路径 |

材料交付见 [server-cli.md](server-cli.md#节点交付与隧道材料)，运行归属与跨网关隔离见 [runtime.md](runtime.md)。public 的 TLS 在 Caddy 终止，Caddy→FRPS 和网关→回环隧道端口留在网关机器内。

## HTTPS 与健康检查

`render.py caddy` 使用 `Caddyfile.tmpl`；路由、浏览器端口、证书签发、复用入口与验收统一见 [reverse-proxy.md](reverse-proxy.md)。public FRPS 检查由 [健康检查安装器](frps-healthcheck.md) 管理，不走本渲染器。

渲染后运行对应验证：`systemd-analyze verify`、`plutil -lint`、计划任务注册后查询，以及 `scripts/validate_deployment.py` 的契约和二进制原生解析。将模板输入、产物、管理器 ID 和检查结果写入运行记录。

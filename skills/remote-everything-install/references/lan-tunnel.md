# 无域名 LAN 隧道

适用于 LAN 网关在远端、节点不能被网关直接访问的部署。设备协议与应用寻址仍采用 LAN 形态，网关到节点使用双向 TLS 隧道。

```text
设备 ── HTTPS + 设备证书 ── LAN 网关 ── 回环节点端口 ── FRPS
                                                       │
节点 ◀── 本机连接 ── FRPC ◀══════ 双向 TLS / TCP ════════╝
```

FRPS 是独立的 FRP v0.70.0 进程，与 public 形态使用相同的外部组件管理方式。`init --tunnel` 分配地址并生成材料，`serve` 只启动 LAN 网关，不启动 FRPS。无须 Caddy、公共 CA 或外部 DNS。

## 初始化与身份

1. 在网关执行 `remote-everything-lan-server init --state <绝对路径> --host <设备能访问的IP> --tunnel --require-approval`。读取真实 `listen_address`、`origin`、`frps_listen`，不假定端口。
2. 每台节点 `init` 后，在网关执行 `node add --state <网关状态> --name <名字> --node-id <节点ID> --node-bootstrap <该节点交付目录>`，省略 `--node-address`。它分配回环隧道地址、签发这台节点的控制令牌与隧道客户端身份。
3. 把交付目录送到节点，执行 `binding add --bootstrap`。将其中 `frpc/` 放入该隧道的最终材料目录，隔离规则见 [runtime.md](runtime.md)。

网关的初始化结果另返回：

| 字段 | 使用者 |
| --- | --- |
| `frps_token_file` | FRPS 认证 token 的文件路径 |
| `tunnel_ca_file` | FRPS 验证隧道客户端的 CA 公钥证书 |
| `tunnel_server_certificate_file` / `tunnel_server_key_file` | FRPS 的服务端证书与私钥 |
| `tunnel_server_name` | FRPC 校验的 TLS 身份名 |

`tunnel_server_name` 是这套安装 CA 签发的内部 TLS 身份，不用于 DNS 查询。FRPC 实际连接 `--host` 指定的 IP 与 `frps_listen` 的端口，同时校验这个身份和交付的 CA。交付材料及私钥归属见 [server-cli.md](server-cli.md#节点交付与隧道材料)。

## 配置与服务

用 `scripts/render.py frps-lan` 与 `frpc-lan`，输入 JSON 通过标准输入或临时文件传入。只包含下表精确字段；端口为整数，路径为目标机器上的绝对路径。

FRPS 输入：

| 字段 | 来源 |
| --- | --- |
| `bind_host` / `frps_port` | `frps_listen` 的主机与端口；监听主机允许 `0.0.0.0` |
| `frps_token_file` / `tunnel_ca_file` | 网关初始化结果中的同名字段 |
| `tunnel_server_cert` / `tunnel_server_key` | 初始化结果的 `tunnel_server_certificate_file` / `tunnel_server_key_file` |
| `frps_log` | 网关侧运行记录中的日志路径 |

每台节点的 FRPC 输入：

| 字段 | 来源 |
| --- | --- |
| `server_host` | 节点能访问的网关 IP；不使用监听通配地址 `0.0.0.0` |
| `server_port` | 网关 `frps_listen` 的端口 |
| `tunnel_server_name` | 初始化结果中的同名字段 |
| `tunnel_ca_file` | 节点侧 `frpc/tunnel-ca.crt.pem` 的最终路径 |
| `tunnel_client_cert` / `tunnel_client_key` | 节点侧隧道客户端证书与私钥的最终路径 |
| `frps_token_file` | 节点侧 `frpc/frps-token` 的最终路径 |
| `frpc_log` | 该节点隧道的日志路径 |
| `node_id` | 节点初始化的 `node_id` |
| `node_host` / `node_port` | 节点自身 `listen_address` 的主机与端口 |
| `node_tunnel_port` | 网关为该节点分配的隧道端口；CLI 字段见 [server-cli.md](server-cli.md#节点增删与令牌续换) |

验证渲染后的配置与两个真实二进制：

```text
python scripts/validate_deployment.py --frp-mode lan --frpc <FRPC> --frpc-config <客户端配置> --frps <FRPS> --frps-config <服务端配置>
```

FRPS 强制 TLS 并验证隧道 CA；FRPC 使用客户端证书、交付的 CA 与指定服务端身份（[FRP TLS 配置字段](https://github.com/fatedier/frp/blob/v0.70.0/pkg/config/v1/common.go)）。仅 FRPS 控制监听面向远端，`proxyBindAddr` 必须为 `127.0.0.1`，每台节点控制面的隧道端口不对公网发布。两端仍使用 wire v2、32 条预建工作连接。

组件分别记录为 `lan`、`frps`、节点侧 `node` 与 `frpc`。节点侧采用用户登录会话服务；Linux 云端的 LAN 网关和 FRPS 采用同一部署账户的系统服务。Windows/macOS 网关仍使用用户会话管理器，只承诺用户登录期间可用。按 [templates.md](templates.md) 渲染相应服务并校验，不手写启动器。

启动顺序：节点 → FRPS → 每台节点的 FRPC → LAN 网关。节点与入口的状态目录独立。外部入站需要放行 LAN 入口、FRPS 控制监听，以及设备实际访问的各应用端口；应用端口从 `open` 结果和 `lan.json` 读取。节点自身控制端口与 FRPS 回环隧道端口不加入公网入站规则。

## 验收与维护

- 用网关记录的该节点令牌，经 `node list` 的该节点 `address` 调用本地控制接口 `list`，确认隧道真的到达节点，不能只检查 FRPS 端口开放。
- 入口启动后签发短期邀请，验证设备配对、批准前拒绝、人工批准、激活、节点目录、应用启停与应用代理；确认无证书和未授权节点请求被拒绝，浏览器路径仍拒绝。
- Linux 端到端验收入口为 `python3 server/lan/tests/accept.py <材料目录>`，材料目录含 Linux 的 `node`、`lan`、`frpc`、`frps`。测试只使用临时目录与高端口，覆盖真实双向 TLS、错误 CA/设备证书拒绝、审批与访问、客户端及服务端证书续期、设备吊销。CI 在 Linux 上运行；LAN 核心行为仍在三平台执行共享测试。
- 升级时，节点侧按 `frpc → node` 停止；网关侧按 `lan → frps` 停止，反序启动。按运行记录匹配精确组件与进程，不影响其他网关。
- `ports repair` 修改 FRPS 监听后，按新的 `frps_listen` 重新渲染 FRPS，并更新各 FRPC 的 `server_port`。节点自身监听改变时更新其 FRPC 的 `node_host/node_port`；回环隧道端口取当前网关记录。
- 隧道客户端证书续期：`tunnel renew --state <网关状态> --node-bootstrap <该节点交付目录>`，重新投递 `frpc/` 并重启该 FRPC；设备配对和节点绑定不变。
- FRPS 服务端证书续期：先停 FRPS，执行 `tunnel server renew --state <网关状态>`，再启动 FRPS 并验证各条隧道。它保留隧道 CA、设备入口证书与端口，FRPC 自动重连，不要求移动设备重新配对。
- `certificate renew` 只更新移动设备访问的 LAN 入口证书，仍按 [device Skill](../../remote-everything-device/SKILL.md) 重新发邀请更新客户端固定信息；它与 FRPS 身份轮换分别处理。
- 巡检检查入口证书、隧道服务端/客户端证书与 CA 的有效期，并验证每个回环隧道上的目录。现有 public 专用的 FRPS 健康检查定时器不自动安装到此模式；FRPS 进程由所选服务管理器管理。该差异应写入验收与运行记录。

# 入口与网关 CLI

下文 `GATEWAY` 替换为 `remote-everything-lan-server`（Windows/Linux/macOS）或 `remote-everything-gateway`（仅 Linux）。所有路径参数使用绝对路径。命令以组件的部署账户执行；public 从 systemd unit 的 `User` 读取账户，首次 init 前先选定该账户。

## 通用命令

```text
GATEWAY node add --state PATH --name NAME --node-id NODE_ID [--link local|tunnel] --node-bootstrap DIRECTORY
GATEWAY node list --state PATH
GATEWAY node remove --state PATH --node NODE
GATEWAY node token renew --state PATH --node NODE --node-bootstrap DIRECTORY
GATEWAY tunnel renew --state PATH --node-bootstrap DIRECTORY
GATEWAY ports repair --state PATH
GATEWAY serve --state PATH
GATEWAY device --state PATH ACTION
```

`device` 的 ACTION、邀请与审批流程见 [device Skill](../../remote-everything-device/SKILL.md)。`--node` 接受节点 ID 或名字；设备请求头只接受 ID。

## 初始化与差异

```text
remote-everything-lan-server init --state PATH --host HOST [--valid-days DAYS] [--applications-host HOST] [--require-approval] [--tunnel]
remote-everything-lan-server node add --state PATH --name NAME --node-id NODE_ID [--node-address HOST:PORT] [--link local|tunnel] --node-bootstrap DIRECTORY
remote-everything-lan-server certificate renew --state PATH [--valid-days DAYS]
remote-everything-lan-server tunnel server renew --state PATH
remote-everything-gateway init --state PATH --origin HTTPS_ORIGIN
```

| 项目 | LAN | public |
| --- | --- | --- |
| 状态 | `lan.json`；含入口证书、应用端口映射与 `applications_host` | `server.json` |
| 监听 | `lan`；启用隧道时另有 `frps` | `status/pairing/frps`，均为 loopback |
| 节点地址 | 给 `--node-address` 时直连；省略时分配隧道地址 | 始终分配回环隧道地址，不接受 `--node-address` |
| 应用地址 | 入口主机上的每应用端口 | 每应用子域名 |

`init` 创建或沿用 installation ID、origin 和监听，不登记节点，也不生成配对二维码。LAN 另返回证书指纹、公钥摘要；`--applications-host` 默认为入口监听主机，可指定具体地址或 `0.0.0.0`。隧道初始化与服务端证书字段见 [lan-tunnel.md](lan-tunnel.md)；public 的 HTTPS 入口见 [reverse-proxy.md](reverse-proxy.md)。

空网关可以运行：健康、设备和邀请管理继续可用；已批准设备的目录返回 `nodes: []`。邀请或追加授权需要已有目标节点。

## 节点增删与令牌续换

`node add` 写入节点 ID、名字、拨号地址和连接声明，并输出交付目录。同 ID 重复添加为原地更新，已有 public 隧道端口保持不变。`--link` 是给客户端的 `local/tunnel` 声明，不决定传输；省略时由实际连接方式推导。客户端的地址兜底显示规则见[行为契约](../../../clients/behavior/README.md)。

节点增删或记录变更按输出的 `restart_required` 重启网关后生效；节点侧绑定的即时生效规则见 [node-cli.md](node-cli.md#初始化与绑定)。输出字段不要混用：

| 来源 | 地址字段 |
| --- | --- |
| `node add` / `node remove` / `node token renew` 单节点结果 | `node_address` |
| `node list` 数组、状态 `nodes[]`、端口修复结果的节点项 | `address` |

`node remove` 删除网关节点记录及其控制令牌，并从所有设备的授权名单移除该节点；不吊销设备本身。节点机器还需撤销对应绑定及隧道材料，操作范围见 [remove Skill](../../remote-everything-remove/SKILL.md)。重新加入同一节点会生成新令牌，不自动恢复设备授权。

控制令牌泄漏、丢失或损坏时，执行 `node token renew`，投递新目录，在节点上 `binding remove` 后 `binding add`，然后重启网关。节点 ID、地址和设备名单保持不变；导入新令牌至网关重启之间有短暂停机窗口。renew 不读取旧令牌，因此令牌文件损坏导致 serve 无法启动时仍可恢复。

## 节点交付与隧道材料

每台节点有独立交付目录。`bootstrap.json` 与 `control-token` 供节点导入；隧道接入另含 `frpc/`：

| 材料 | 用途 |
| --- | --- |
| `frps-token` | 该网关各隧道共用的 FRP token |
| `tunnel-client.crt.pem` / `tunnel-client.key.pem` | 该节点的隧道客户端身份 |
| `tunnel-ca.crt.pem` | LAN 隧道验证直连 FRPS；public 仍使用系统信任验证 HTTPS 入口 |

CA 私钥及 FRPS 服务端私钥留在网关。交付目录按网关级机密保护：隧道 token 能发布代理端口；它不是逐节点控制授权。已有目录须匹配网关身份和 CA，重复生成保留客户端身份。

通过加密管理通道投递，导入并核对两端 installation ID；长期材料只放最终状态目录，删除传输副本。材料位置和复用节点的 owner 见 [runtime.md](runtime.md)，FRPC 配置字段见 [templates.md](templates.md#frp-配置)。

`tunnel renew` 用同一 CA 续换指定目录中的客户端证书。重投 `frpc/` 并重启该 FRPC；节点绑定、设备授权和端口不变，节点无需重启。旧证书在到期前仍受同一 CA 信任，因此这不是即时吊销操作。

## 网关端口与应用路由

停服后执行 `ports repair`，同步 runtime、FRP 与 HTTPS 上游引用再启动。它保留身份、证书及节点声明；public 还重分配每台节点的隧道端口，须据新 `nodes[].address` 更新对应 FRPC 的 `node_tunnel_port` 并重装[健康检查](frps-healthcheck.md)。LAN 的入口端口变化会改变 origin，需重新发邀请。

除节点目录 `/__remote_everything/nodes` 外，面向某节点的设备协议请求须带 `X-Remote-Everything-Node: <node_id>`。缺头返回 `401 node_required`，未知或未授权节点返回 `401 unauthorized`。

`open/<app>` 返回 302 与绝对应用 origin；核心接口不设置路由 Cookie，浏览器会话会另附一次性票据。应用请求由 origin 确定节点和应用，网关剥离客户端伪造的路由 Cookie，再为节点设置内部路由。应用 origin 上控制路径为 403、协议路径为 404；入口的非协议应用路径为 404。地址在持久化映射有效时保持稳定，LAN 应用端口被占用后可重新分配。Cookie 边界只见[应用信任说明](../../remote-everything-app/SKILL.md#应用信任边界)。

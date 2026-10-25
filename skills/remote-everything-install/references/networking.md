# 网络拓扑与域名选择

节点、网关和设备的身份关系见 [AGENTS.md](../../../AGENTS.md#架构)。设备请求先到网关；节点控制接口和原始应用端口不是移动客户端入口。

## 选择拓扑

| 条件 | 选择 | 后续参考 |
| --- | --- | --- |
| 网关能经局域网或已有 VPN/组网直接访问节点 | 直连 LAN | 下节 |
| 有远端服务器，需节点主动建立隧道，但不使用域名、公共 CA 或 443 入口 | LAN 隧道 | [lan-tunnel.md](lan-tunnel.md) |
| 有 Linux 服务器、可用域名与 443 控制权；需要公共证书或浏览器入口 | public | [域名选择](#域名选择)及 [reverse-proxy.md](reverse-proxy.md) |
| 既无可达服务器，也不能直连 | 先建立远程组网，再用直连 LAN | 先验证设备和网关可达，再部署 |

应用的信任前提与浏览器限制见[应用信任边界](../../remote-everything-app/SKILL.md#应用信任边界)。

## 直连 LAN

网关和节点可以同机，也可以分处可互通的机器：同机节点使用默认 loopback 监听；异机节点监听网关可达的具体地址，网关以 `node add --node-address` 记录该地址。

设备通过 HTTPS 和设备证书访问网关，使用二维码中的固定信息验证入口证书；网关到节点是明文 HTTP。这段网络必须受控：节点控制接口有令牌鉴权，但节点的应用代理不再验证设备身份。因此只向网关所在地址或必要网段开放节点端口；跨不可信网络选隧道。

设备需要访问 LAN 入口及网关分配的各应用端口。入口地址从 `init` 输出取，应用地址从 `open` 和持久化映射取；在防火墙中限定设备所在网段或组网接口。

## 域名选择

public 的网关主机为 `<domain>`，应用主机为 `<app>.<node_id前8位>.<domain>`。有两种取值方式：

- 自有域名：为网关基础域名设置指向入口的 A/AAAA 记录，再为应用子域设置 `*.<domain>` 通配记录；更近的 DNS 节点可能阻止通配合成，部署前必须检查真实应用主机的解析结果，见 [RFC 4592](https://www.rfc-editor.org/rfc/rfc4592.html#section-3.3.1)。
- IP 泛解析域名：可选 `nip.io` 或 `sslip.io` 一类服务，无需自己维护解析。示例 `203-0-113-10.nip.io` 只展示命名方式，实际替换为服务器地址；部署前核对网关和应用子域的解析、TLS 与网络可达性。

Caddy 在基础域名前匹配两层应用标签，证书逐主机按需签发；DNS 通配解析与证书通配是不同机制。TLS 与既有入口合并要求见 [reverse-proxy.md](reverse-proxy.md)。

同一公网主机也可以运行节点：按相同流程建立本机 FRPC 和绑定，网关与节点各用独立状态目录。多网关的域名、服务及共享节点管理见 [multi-computer.md](multi-computer.md)。

## 换域名或地址

public 改域名时，同步网关状态中的 `origin`、Caddy 主机与 FRPC 的 `public_host`，验证完整配置后重载入口、重启网关和 FRPC，再按 device Skill 重新配对；原 origin 的客户端连接不能继续使用。更新公开访问规则，并从外网验证握手、配对与应用访问。

如果应用按 Host/Origin 做白名单校验，按 [适配器说明](../../remote-everything-app/references/patterns.md#适配器adapterjs) 让它看到自己认识的 origin。SNI 重置、客户端代理/Fake-IP 分流与“本机可达、外网不可达”的排查集中在 [troubleshooting.md](../../remote-everything-inspect/references/troubleshooting.md)。

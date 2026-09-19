# 公网 443 入口

从 `server.json` 读取真实上游地址。入口必须：

1. 以受系统信任的服务端证书提供独立 HTTPS 域名。
2. 仅让 `/__remote_everything_pair` 无客户端证书访问配对上游。
3. 让 `/__remote_everything_activate` 和其他设备路径验证设备 CA，把实际客户端叶证书 SHA-256 指纹覆盖写入 `X-Remote-Everything-Client-Fingerprint` 后转发状态上游。
4. 让精确 FRP WSS 路径只验证独立隧道 CA 并转发 FRPS loopback 上游。
5. 丢弃客户端提交的同名指纹头；所有项目上游保持 loopback。
6. 对设备页面的可压缩响应启用 Zstandard/Gzip 内容编码，避免大型前端资源在公网链路上原样传输。
7. FRP v0.70.0 的客户端 `transport.poolCount` 与服务端 `transport.maxPoolCount` 均固定为 32。设备流量经 Caddy 进网关再进节点隧道，当前 Caddy 模板不对上游做 `max_conns` 限流，并发上限由该工作连接池约束；多设备、长期 WebSocket 与目录轮询共用同一池，过小会打满后触发丢连接与重连抖动。
8. **每个应用一个主机**：`<应用>.<节点前缀>.<域名>`（节点前缀 = `node_id` 前 8 位十六进制）。证书按需签发（`tls { on_demand }`），签发前由 `on_demand_tls` 的 ask 端点向网关确认这台主机确实是它当前在服务的（网关只服务回环来源，节点离线或应用不在目录里一律 403）。应用站点与网关站点用同一个 device 匹配器、同一份 client_auth、同一个状态上游；只有设备证书的请求到达网关，网关按 Host 分流。

**部署前提**：
- **若使用自有域名**：DNS 需要一条 `*.<域名>` 通配 A/AAAA 记录，指向入口所在主机。应用主机是两个 label（`<应用>.<节点前缀>`）加域名，但 DNS 通配记录按 RFC 4592 会覆盖没有更近节点存在的多级名字，所以一条 `*.<域名>` 就够。
- **若使用 IP 泛解析域名（可选且推荐）**：使用中划线格式的 IP 泛解析域名（首选 `47-97-117-46.nip.io`，备选 `47-97-117-46.sslip.io`），公共 DNS 基础设施天然递归泛解析任意多级子域名到对应公网 IP，无需在任何 DNS 控制台手动配置解析记录。
- Caddy 侧统一配置为 `https://*.*.<PUBLIC_HOST>`（Caddy 的 `*` 只匹配一个 label，中划线格式确保 PUBLIC_HOST 作为一个 label 参与匹配）。证书不是通配证书：每个应用主机一张，按需签发，因此不发多级通配证书也能工作。

先以能够读取 socket PID 的权限运行 `scripts/inspect_443.py`。脚本从 443 监听 PID 的 cgroup 精确解析 systemd unit 与 FragmentPath；非 systemd 进程返回真实 executable。端口已占用但 PID 不可见、系统命令失败或 unit 定义不明确时脚本以 `ok:false` 失败，不猜测 owner。然后检查该 owner 的证书验证、issuer 路由、WebSocket 和叶证书 SHA-256 指纹能力。满足契约时生成只包含本站点的最小片段，验证完整配置后原子重载，并记录真实插入点和恢复方法。

没有现有入口时，在 `.runtime/bin/` 安装固定版本 Caddy，使用项目模板渲染完整站点，并用 `render.py caddy-systemd` 生成非 root 独立服务。服务只获得绑定 443 的 capability，证书数据与自动配置目录都位于 `.runtime`。模板同时关闭 HTTP 重定向与 ACME HTTP-01，只使用 443 的 TLS-ALPN 完成证书签发（网关站点启动时签，应用站点在该主机第一次被访问时签），不新增 80 监听。设备路径与隧道路由必须使用不同 CA 匹配器，不得把两个 CA 混成同一可访问集合。

验收：无证书只能访问配对；pending 只能提交或轮询审批；人工批准前不能访问应用；approved 可访问；伪造指纹无效；吊销立即失败；FRPC 只能通过专用 WSS 路径连接；每个应用在各自的 origin 上被打开与访问、且该 origin 只服务那个应用；没有新增公网业务端口。

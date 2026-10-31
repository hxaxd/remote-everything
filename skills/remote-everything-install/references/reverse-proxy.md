# Public HTTPS 入口

从网关状态读取 `status`、`pairing`、`frps` 的真实 loopback 地址。域名与 DNS 按 [networking.md](networking.md#域名选择) 选择；证书及组件版本按 [releases.md](releases.md)。

## 路由与认证

当前 `Caddyfile.tmpl` 为一个网关生成以下站点和路由：

| 站点/请求 | 入口与网关分工 |
| --- | --- |
| 网关 443：`/__remote_everything_pair` | 无设备证书即可到 pairing 上游；网关验证单次邀请 |
| 网关 443：精确 `/~!frp` | 入口按隧道 CA 的 issuer 放行到 FRPS |
| 网关 443：`/web`、`/web/*`、`/__remote_everything_web_*` 及携带 Web Cookie 的协议请求 | 转给 status，由网关校验浏览器凭据 |
| 网关 443：其余设备请求 | 验证设备 CA，覆盖写入真实叶证书 SHA-256 指纹，再转给 status；未匹配请求返回 401 |
| `https://*.*.<domain>`：应用主机 | 设备证书、Web 票据或 Web Cookie 进入 status；网关校验节点权限，决定具体应用路由 |
| `<domain>:8443`：默认浏览器站点 | 不要求客户端证书，转给 status；访问权限仍由网关浏览器会话决定 |

所有无设备证书转发分支都删除客户端自报的指纹头；设备分支写入 `X-Remote-Everything-Client-Fingerprint`。设备与隧道使用不同 CA/issuer 路由；网关应用代理再过滤内部凭据。

设备和隧道使用 443；默认模板另外监听 8443。实际提供浏览器高端口访问时，要在主机防火墙和云安全组放行并从外网验证，不能以服务器本机 curl 代替。模板关闭 HTTP 重定向和 HTTP-01，使用 TLS-ALPN-01，因此不新增 80 监听；这不保证任何域名在任意网络都能签发证书。

应用证书使用 `tls { on_demand }`，全局 ask 请求 `GET /__remote_everything_tls_ask?domain=<host>`；网关仅接受回环请求，并要求主机属于它服务的节点且应用目录可达，返回 200 或 403。该机制见 [Caddy 官方说明](https://caddyserver.com/docs/automatic-https#on-demand-tls)。

## 安装或接入既有入口

先用能读取 socket PID 的权限执行 `scripts/inspect_443.py`，按 PID/cgroup 查真实 systemd unit 与 FragmentPath，非 systemd 进程读取真实 executable；不可见或不明确时先补足观测，不能猜 owner。

既有入口满足证书验证、issuer 分流、WebSocket 与指纹覆盖契约时，只生成本部署的配置片段。合并后验证完整配置，再原子重载，记录插入点和恢复方法；多网关共享的额外条件见 [multi-computer.md](multi-computer.md#多个网关共享服务器)。

没有既有入口时，按 [templates.md](templates.md) 安装项目 Caddy 系统服务：非 root 部署账户、绑定低端口的 capability、运行目录内的证书数据和自动配置。设备页面可压缩响应启用 zstd/gzip；反代不设置 `max_conns`，FRP 工作连接池参数见模板参考。

## 验收

分别验证证书设备、浏览器与隧道：无效邀请拒绝；设备批准前不能访问节点；批准后可访问；伪造指纹无效；吊销后拒绝。浏览器入口可公开加载，但控制与应用请求仍需有效会话。检查每个应用在自己的 origin 上打开、FRPC 仅通过专用 WSS 路由接入，并确认实际监听和外部放行范围与运行记录一致。

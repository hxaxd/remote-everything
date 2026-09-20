# 安全策略 / Security Policy

[中文](#中文) · [English](#english)

## 中文

### 报告

[GitHub 私密漏洞报告](https://github.com/hxaxd/remote-everything/security/advisories/new)。不可用时开一个不含细节的公开 Issue，再约私密渠道。

目标：7 天内确认收到；14 天内初步判断或追问。披露节奏与维护者协调。

### 范围

配对与设备状态；mTLS / 指纹 / 吊销；网关→节点控制令牌；反向代理路径、Host、Cookie、WebSocket；客户端凭据与 Web 隔离；Skill / 发布链路。

### Web 客户端的信任模型

网关托管的浏览器客户端与证书设备共用同一套设备记录与准入，但它持有的凭据不同，边界如下（均为有意设计，不作为漏洞受理；要改变请开普通 Issue 讨论）：

- **clientID 是浏览器的长期 bearer 凭证**。首次配对需要有效邀请；此后浏览器凭本地保存的 clientID（64 位 hex，存于 localStorage）即可换回自己的设备身份与会话。它等价于证书设备手里的证书文件：不过期、不与邀请绑定，泄露即等于设备被冒用，直到操作者 `device revoke`。会话 Cookie（30 天）只是便利层——信任层每个请求都会重查设备记录，吊销后旧会话即刻失效，且吊销会同时清掉该设备的全部 Web 会话。
- **Web 配对端点与 mTLS 配对端点共用同一套限流**（每 IP / 全局窗口、并发上限、失败延迟），不存在未设防的门。
- **应用 origin 的跨域跳转用一次性票据**（1 分钟、单次使用）：票据只把"这台浏览器是哪个设备"从协议 origin 带到应用 origin，兑换即作废。
- **Web 会话 Cookie 属于网关而非应用**：它在代理转发前被剥离，应用永远看不到；应用也无法改写它（响应侧同名单剥离）。
- **Web 客户端只在公网形态提供，局域网形态不提供**。Cookie 的作用范围按主机而不按端口：LAN 形态下应用与入口是同一主机的不同端口，一个浏览器入口会让每个应用页面与入口共享同一个 Cookie 罐——应用页面能写入口会收到的 Cookie，也能读入口未标 HttpOnly 的 Cookie。公网形态下应用是网关域的子域，会话 Cookie 以 `__Host-` 前缀下发（浏览器强制这个名字只能由设置它的主机读写、网页脚本覆盖不了），网关另会剥掉应用自己下发 Cookie 的域范围；残留的、网关无法消除的风险是应用页面里的脚本仍可写父域 Cookie，因此公网形态的 Web 客户端是**允许但不推荐**，且只应接入可信应用。
- 撤销边界与证书设备一致：`device revoke` 拒绝设备本体；`--node` 只收回单台节点，会话保留。

**已经声明的边界，不作为漏洞受理**：LAN 形态里网关与节点之间的那段链路按可信网络对待（控制令牌与应用流量都在这张网上，节点自身的应用数据面不再另做鉴权），见 [README 安全模型](README.md#安全模型)。这不是待修的缺口而是有意的取舍：要跨不可信网络就用公网形态，那条路上离开机器的每一跳都是 TLS。想改变这个决定，请开普通 Issue 讨论。

其它问题见 [CONTRIBUTING.md](CONTRIBUTING.md)。

## English

### Reporting

[GitHub private vulnerability reporting](https://github.com/hxaxd/remote-everything/security/advisories/new). If unavailable, open a public Issue with no details, then arrange a private channel.

Target: acknowledge within 7 days; initial assessment or follow-up questions within 14 days. Coordinate disclosure timing with maintainers.

### Scope

Pairing and device state; mTLS / fingerprints / revocation; gateway→node control tokens; reverse-proxy path, Host, Cookie, WebSocket; client credentials and Web isolation; Skill / release pipeline.

### The web client's trust model

The gateway-hosted browser client shares one device store and one admission with certificate devices, but it holds a different credential, and its boundaries are as follows (all deliberate design, not accepted as vulnerabilities; to change one, open an ordinary Issue):

- **The client id is the browser's long-lived bearer credential.** The first pairing needs a valid invitation; from then on the browser presents the client id it keeps locally (64 hex characters, in localStorage) and is answered with its own device identity and session. It is what the certificate file is to a certificate device: it does not expire, it binds to no invitation, and its disclosure is device impersonation until the operator revokes it. The session cookie (30 days) is a convenience layer only — the trust re-reads the device record on every request, a revoked device is refused at once, and a revoke also clears every web session kept for it.
- **The web pairing endpoint shares one rate-limit budget with the mTLS pairing endpoint** (per-IP and global windows, a concurrency cap, and a delay before a refusal); no door to pairing is left unguarded.
- **Cross-origin handoff to an application origin uses a one-time ticket** (1 minute, single use): the ticket carries only which device this browser is, from the protocol origin to the application origin, and is consumed on redemption.
- **The web session cookie belongs to the gateway and not to any application**: it is stripped before an application is proxied to, and an application cannot write it either.
- **The web client is served in public mode only, never in LAN mode.** Cookies are kept by host and not by port: in LAN mode an application and the entrance are ports of one host, so a browser entrance would give every application page one cookie jar shared with the entrance — an application page could write cookies the entrance receives and read every cookie of the entrance's that is not HttpOnly. In public mode an application is a subdomain of the gateway's domain, the session cookie is issued under the `__Host-` prefix (the browser binds that name to the one host that set it and refuses to let a script overwrite it), and the gateway strips the domain from cookies an application sets itself; what remains, and what the gateway cannot remove, is that a script on an application page can still write a parent-domain cookie — so the public-mode web client is **allowed but not recommended**, and only trusted applications should be reached through it.
- Revocation boundaries match certificate devices: `device revoke` refuses the device itself; `--node` withdraws one node and leaves the session.

**Declared boundaries, not accepted as vulnerabilities**: in LAN mode the Gateway–Node path is treated as a trusted network — the control token and application traffic both travel on it, and the node's own application data plane carries no further authentication. See the [security model](README_EN.md#security-model). That is a deliberate trade-off rather than a gap waiting to be closed: to cross an untrusted network, use public mode, where every hop that leaves a machine is TLS. To change that decision, open an ordinary Issue.

Everything else: [CONTRIBUTING.md](CONTRIBUTING.md).

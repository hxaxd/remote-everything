# 网络拓扑

一个节点就是一台机器（一个 `node_id`），一个网关服务它旗下的一台或多台节点；每个网关绑定 = 一个 `installation_id` = 移动客户端一条路（一个 Profile），手动切换。网关和节点不必同机：LAN 形态要求两者在同一局域网内，公网形态经隧道相连。
多台电脑部署详见 [multi-computer.md](multi-computer.md)。

控制面的请求总是先到网关，由网关按 `X-Remote-Everything-Node` 决定送给哪台节点——这条头是内部头，应用永远看不到它；应用流量则发生在各应用自己的 origin 上，哪个节点哪个应用由 origin 决定（网关转发时自己补上节点侧的路由 cookie）。没有"手机不经网关直连节点"这条路：能验证设备证书的是网关那一跳，判权限的也是它。

## 1. 局域网或虚拟组网直连（LAN / VPN）

运行节点和 LAN 入口，两者可以在同一台机器上，也可以在同一局域网内的两台机器上。

- 同机：节点 `init --listen 127.0.0.1`（缺省），节点端口只在本机可达。
- 不同机：节点 `init --listen <该节点所在机器的局域网地址>`，入口 `node add --node-address <同一地址:端口>`，两者必须一致。

入口的动态端口写入 `lan.json` 与二维码，防火墙只允许移动设备所在 LAN 网段或组网接口访问它。不同机时节点端口也必须对入口所在的那台机器可达：该端口用控制令牌保护控制接口，但应用代理对任何能连上它的主机开放，和入口自身的暴露是同一层级，因此只放行入口所在地址或所在网段，不要开给更大的范围。

异地且没有公网服务器时，先与用户对齐是否已有远程组网：有则复用，没有则推荐免费虚拟组网 Tailscale 并指导建立。验证目标移动客户端与节点均在线、节点地址稳定且入口端口可达后按直连 LAN 形态部署。

## 2. 无域名公网/远端穿透（No-Domain Remote LAN with Tunnel）

当用户拥有云服务器或远端公网 IP，但**没有域名**（或无法开放 443 端口、不想购买域名及维护 DNS 泛解析/证书签发）时，采用带隧道的 LAN 入口形态：

```text
移动客户端(手机/平板) ── HTTPS(SPKI钉扎) ────┐
                                           ├── LAN入口端口 ── [本地回环 或 隧道端口] ── 节点
普通Web浏览器(PC/手机) ─ HTTPS(WebSession) ──┘
每台节点(家/公司电脑) ──── TLS/FRPC 隧道 ─────── LAN内置FRPS端口 ── 回环隧道端口
```

- **部署命令**：`remote-everything-lan-server init --state PATH --host <公网IP/远端IP> --tunnel --require-approval`
- **节点接入**：在网关上 `remote-everything-lan-server node add --state PATH --name <名字> --node-id <NODE_ID> --node-bootstrap <目录>`（省略 `--node-address`，网关自动分配隧道端口并输出 `frpc/` 材料）；节点端导入身份并启动 FRPC 隧道连接网关的 FRPS 监听端口。
- **免域名高安全**：
  - **移动端**：原生 App（Android / iOS / HarmonyOS）直接钉扎入口自签证书的 SPKI，无需公共商业 CA 证书，防中间人窃听与伪造，不产生任何证书红脸。
  - **Web 浏览器**：普通浏览器访问 `https://<IP>:<port>/`，利用网关内置的纯前端单页面应用（SPA）与 WebCrypto 加密保险箱，通过 HttpOnly Cookie 建立经过管理员人工审批（`device approve`）的安全会话。
  - **应用地址与存储**：各应用由 LAN 网关在远端分配独立端口（`https://<IP>:<app_port>/`），浏览器同源策略隔离页面、LocalStorage 与 IndexedDB，无需子域名泛解析；Cookie 不按端口隔离，接入时遵循[应用信任边界](../../remote-everything-app/SKILL.md#应用信任边界)。

## 3. Linux 域名公网服务器（Public 443）

当用户拥有 Linux 云服务器、独立公网域名、以及 443 端口完整控制权时采用：

```text
移动客户端 ── HTTPS/mTLS ── 443入口 ── 网关状态端口 ── 节点隧道端口（每台节点一个）
移动客户端 ── HTTPS邀请 ─── 443入口 ── 网关配对端口
每台节点 ───── WSS/443 ───── 443入口 ── FRPS端口 ── 各自的隧道端口
Web浏览器 ─── HTTPS(8443) ── 8443入口 ── 网关状态端口 ── 节点隧道端口（免客户端证书，直通Web客户端与代理）
```

`status`、`pairing`、`frps` 三个服务器内部端口均从 `server.json` 读取且只监听 loopback；每台节点的隧道端口记在该节点条目里（`node_address`），也是 loopback，由同一个 frps 按 `remotePort` 暴露。移动客户端 App 走标准的 443 端口与正式公网证书，强校验 mTLS 设备凭据，未带证书的普通公网请求直接放行给服务器原有的网站/Nginx（互不抢占根路径）；普通 Web 浏览器访问专用的 8443 高端口，复用公网 CA 证书，免客户端证书即可加载网关内嵌的 SPA 客户端并通过 Web 会话直达各节点受管应用。**8443 必须在云安全组放行入站**：Caddy 侧配好、服务器上 `curl 127.0.0.1:8443` 返回 200，都不代表外网能连——入站规则在云控制台，机器上看不到；每次换机器或换端口都要从外网 vantage 复测一次。（2026-09-19 现网就是这样：配着、本机通、外网不通。）网关初始化一次生成安装 ID、隧道 CA 与 FRPS token，并为**每台节点**签发一份控制令牌；隧道 CA 私钥只留在服务器。节点只接收安装 ID 与该节点自己的控制令牌；跑在节点机器上的隧道代理另外拿到 FRPS token 与自己的客户端身份——由网关在同一个交付目录里给出，见 [server-cli.md](server-cli.md)。

节点与公网服务器同机时同样按公网形态部署：bootstrap bundle 本机传递即可，那台节点的 FRPC 连接本机 443，经反向代理回环到本机 FRPS；全部组件端口都是动态 loopback，互不冲突。两侧各自使用独立的项目副本与 `.runtime/`，运行记录、状态与日志互不相干，移除任一侧不影响另一侧。

### 域名选型与 Origin 隔离策略（自由可选，非强制绑定）

Public 形态为**每个应用分配独立 Web Origin**（形如 `https://<appID>.<nodePrefix>.<domain>/`），浏览器同源策略限制跨应用的页面及 LocalStorage、SessionStorage、IndexedDB 访问。Cookie 不遵循相同的隔离边界：当前同父域布局仍允许应用脚本写父域 Cookie，接入时遵循[应用信任边界](../../remote-everything-app/SKILL.md#应用信任边界)。

为了支撑多级子域名隔离，Remote Everything 提供完全自由、非强制绑定的域名选型路径：

1. **分支 A：自有独立域名（Custom Domain）**
   - **适用场景**：用户持有已备案/受信任的自有域名（如 `example.com`），适合长期生产部署。
   - **DNS 配置**：在域名解析商处添加一条泛解析记录：`*.example.com -> <服务器公网IP>`。
   - **证书与路由**：Caddy 通过 `https://*.*.example.com` 模板自动匹配两级子域名，并结合 TLS-ALPN-01 自动化按需签发证书。

2. **分支 B：IP 泛解析域名（Wildcard IP DNS，可选且推荐的零门槛方案）**
   - **适用场景**：用户拥有公网 IP，但没有自有域名、不想购买域名或不想维护 DNS 解析记录。
   - **实现方案**：利用公共 IP 泛解析基础设施（首选 `nip.io`，备选 `sslip.io`），直接将公网 IP 转化为全功能子域名：
     - **网关 Origin 示例**：`https://47-97-117-46.nip.io`（或 `https://47-97-117-46.sslip.io`）
     - **应用 Origin 示例**：`https://dsh.457b963f.47-97-117-46.nip.io/`
   - **核心优势**：
     - **零配置**：公共 DNS 服务器自动将任何 `*.<ip-with-hyphens>.nip.io` 解析回该 IP，无需手动添加任何 DNS 记录。
     - **绕过 80 端口拦截**：国内主流云厂商（如阿里云、腾讯云）默认封禁未备案域名的 80 端口 HTTP 访问，导致标准 HTTP-01 证书申请失败。而 Remote Everything 的 Caddy 配置固定使用 `disable_http_challenge`，完全经由 443 端口的 **TLS-ALPN-01** 挑战与 Let's Encrypt 交互，即便在未备案云服务器上也能秒级自动完成证书签发。
   - **规范与避坑要点**：
     - **必须使用中划线命名（Dash Notation）**：域名必须形如 `47-97-117-46.nip.io`，**严禁使用点分格式** `47.97.117.46.nip.io`！点分格式会将 IPv4 的 4 个数字段识别为 4 个独立 DNS label，叠加应用前缀后总共有 6 级 label，而 Caddy 模板的 `https://*.*.{{PUBLIC_HOST}}` 仅匹配两级通配 label，点分格式会导致 Caddy 无法匹配路由。中划线格式将 IP 收敛为一个单一 label，与模板 100% 契合。
     - **域名选型必须实测连通（2026-09-19 实测）**：`*.sslip.io` 在部分链路上被按 SNI 直接 RST——TCP 能建连、DNS 正常解析、ICMP 可达，但 ClientHello 里带 `sslip.io` 域名就被重置；同一 IP 直接访问与 `*.nip.io` 完全正常。因此**默认选 `nip.io`**，换域名后必须用外网 vantage（或手机蜂窝/WiFi 各测一次）验证 `https://<域名>/web/` 真能握手成功，不能只看本机 curl——同机 curl 走云内回环，可能绕过云厂商对未备案域名的 SNI 拦截。**换域名的完整动作**：替换 Caddyfile 与 `server.json` 的 origin → `caddy reload` → 重启网关 → 客户端重新发码配对（旧 profile 要在客户端删掉）→ **让按请求主机名做白名单的应用认识新名字**：正解是在它的 adapter 里把 `Host`/`Origin`/`Referer` 说成应用自己的 origin（见 [patterns.md](../../remote-everything-app/references/patterns.md) 的适配器一节），**不需要**每换一次入口就重登记；症状是页面外壳能开、一调 API 就 403（DSH 的 `--trusted-host` 即此类，见 `apps/dsh/NOTES.md`）。
     - **客户端本地代理分流考量**：若客户端设备（手机或电脑）开启了全局科学上网工具（如 Clash / Mihomo 的 Fake-IP TUN 模式），域名的解析与出站都发生在代理侧：代理软件可能把它误判为境外流量而分配 `198.18.x.x` 保留 IP，或经境外节点回连国内服务器。真遇到连不上时，先把 App 加进「应用访问控制」的绕过名单（FlClash 实测：勾选后需重启一次隧道生效）或把 `<PUBLIC_IP>.nip.io` 加进 **DIRECT（直连）** 规则来排除代理因素；但注意**这不能治 SNI 拦截**——2026-09-19 实测中，绕过代理后连不上依旧，改域名（sslip.io → nip.io）才是修复。

3. **分支 C：无域名纯 IP 隧道 LAN 网关（Tunnel LAN Gateway）**
   - **适用场景**：无域名，且**不希望依赖任何第三方公网 DNS 泛解析服务**，或 443 端口被运营商完全封锁。
   - **实现方案**：执行 `remote-everything-lan-server init --host <公网IP> --tunnel --require-approval`。
   - **隔离与信任模型**：
     - 移动端 App 通过 SPKI 公钥强钉扎直接与云端自签证书通信，零外部 CA 依赖；
     - Web 客户端与受管应用在云端分配独立高端口（如 `https://<IP>:8443/`、`https://<IP>:9001/`），浏览器以「协议+主机+端口」为维度隔离页面与本地存储，Cookie 不按端口隔离；不需任何子域名解析。

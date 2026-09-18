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
  - **应用沙箱隔离**：各应用由 LAN 网关在远端分配独立端口（`https://<IP>:<app_port>/`），完全依靠浏览器原生同源策略实现存储隔离，无需子域名泛解析。

## 3. Linux 域名公网服务器（Public 443）

当用户拥有 Linux 云服务器、独立公网域名、以及 443 端口完整控制权时采用：

```text
移动客户端 ── HTTPS/mTLS ── 443入口 ── 网关状态端口 ── 节点隧道端口（每台节点一个）
移动客户端 ── HTTPS邀请 ─── 443入口 ── 网关配对端口
每台节点 ───── WSS/443 ───── 443入口 ── FRPS端口 ── 各自的隧道端口
```

`status`、`pairing`、`frps` 三个服务器内部端口均从 `server.json` 读取且只监听 loopback；每台节点的隧道端口记在该节点条目里（`node_address`），也是 loopback，由同一个 frps 按 `remotePort` 暴露。公网只新增既有 443 流量；22 仅用于既有管理。网关初始化一次生成安装 ID、隧道 CA 与 FRPS token，并为**每台节点**签发一份控制令牌；隧道 CA 私钥只留在服务器。节点只接收安装 ID 与该节点自己的控制令牌；跑在节点机器上的隧道代理另外拿到 FRPS token 与自己的客户端身份——由网关在同一个交付目录里给出，见 [server-cli.md](server-cli.md)。

节点与公网服务器同机时同样按公网形态部署：bootstrap bundle 本机传递即可，那台节点的 FRPC 连接本机 443，经反向代理回环到本机 FRPS；全部组件端口都是动态 loopback，互不冲突。两侧各自使用独立的项目副本与 `.runtime/`，运行记录、状态与日志互不相干，移除任一侧不影响另一侧。

# 入口与网关 CLI

两种入口记录的是同一件事：**身份 + 对外 origin + 具名监听 + 它服务的节点**。`installation_id` 决定节点把它绑成谁；`origin` 是客户端拨它的地址，也是每条邀请指向的地址，初始化时写一次，之后所有 `device invite` 都从状态里取，不再需要操作者每次手敲；监听列表说的是它在哪些地址上服务，每条都有名字（LAN 是 `lan`；公网网关是 `status`、`pairing`、`frps`），因为渲染模板、运行记录和操作者都是按角色而不是按位置来引用它们的；节点列表说的是它后面有哪些机器，每条记着节点的 `node_id`、操作者给它起的名字，以及这个入口拨它的地址。

节点不在 `init` 里。`init` 建的是入口自己——身份、证书、origin、自己的监听、自己的隧道——节点由 `node add` 一台一台加进来，因为每台节点都要单独交付到它那台机器上，也可能在入口已经跑起来之后才加。**`node add` 对运行中的入口不生效**：入口在启动时读状态，加完节点要重启才服务它（`node add` 的输出里有 `restart_required`）。`node list` 读出当前记录的全部节点，`device invite` / `device grant` / `node remove` / `node token renew` 的 `--node` 接受节点的 `node_id` 或那个名字。

**请求怎么说明它要哪台**：除了 `/__remote_everything/nodes`（它问的是"我手里有哪几台"，不是"去哪台"，所以它不带节点头、也不该带——不然一个设备在不知道新节点头的情况下就发现不了它），其余每个已认证请求都必须带 `X-Remote-Everything-Node: <目标节点 node_id>`；不带、带一个这个入口不服务的、或带一个该设备没被授权的，一律 `401`（`node_required` / `unauthorized`，后两种情况回答同一个 code，不告诉设备哪台存在）。`/__remote_everything/open/<app>` 说的是"这次浏览器会话看哪个应用"，不是"你有没有资格看它"：授权粒度是节点，一台设备能进它持有的节点上的任何应用。

**每个应用有自己的 origin**：`open` 回答 `302` + 绝对 `Location`（应用 origin 的根路径），不设任何 cookie；客户端随后加载的就是那个 origin。公网形态是 `https://<app>.<节点 node_id 前 8 位十六进制>.<网关域名>`，局域网形态是 `https://<入口自己的主机>:<每应用端口>`。应用 origin 上的一切都由网关解析出 (节点, 应用)、按与其它请求同一套规则校验设备对节点的授权，然后由网关自己把内部路由 cookie 写给节点（先剥掉客户端送来的同名 cookie——选哪个应用由 origin 决定，不由客户端决定）；节点侧照旧只读这个 cookie。应用 origin 上 `/__local_remote_control` 一律 `403`，所有 `/__remote_everything*` 一律 `404`（控制面与协议端点不在这里）。入口自己的 origin 上反过来：不是协议端点的路径一律 `404`，应用流量不在这里。应用 origin 对同一个应用是稳定的（公网按名字推导、局域网按持久化端口），浏览器的存储因此一直属于同一个应用。

**入口怎么拿到应用主机的证书**：公网入口对每个应用主机按需签发，签发前问网关 `GET /__remote_everything_tls_ask?domain=<host>`——它不需要设备证书（入口自己没有设备身份），只服务回环来源（入口在这台机器上）；域名必须是本网关域名下的应用主机、前缀属于本入口服务的某台节点、且那台节点确实在跑那个应用（节点离线即拒绝）。返回 200 允许、403 拒绝，没有别的答案。

文件因此也只差一点：`server.json` 就是这份状态本身；`lan.json` 是同一份状态再加一个 `lan` 块（入口自己的证书文件与指纹）与一个 `applications` 列表（这个入口服务过的每个应用：`node_id`、`app_id` 与它自己的端口）。`ports repair` 是同一套实现——保住每条监听的名字与主机，只把端口搬走（LAN 的 origin 含端口，所以搬端口时 origin 跟着变；公网网关连每台节点的隧道端口一起搬，因为那些端口是它自己的隧道服务器持有的）。CLI 输出仍然用具名字段（`status_listen`、`listen_address`、`node_address`……），部署模板与运行记录按这些名字取值，不受状态文件内部结构影响。

## LAN：Windows、Linux、macOS

```text
remote-everything-lan-server init --state PATH --host HOST [--valid-days DAYS]
remote-everything-lan-server node add --state PATH --name NAME --node-id NODE_ID --node-address HOST:PORT --node-bootstrap ABSOLUTE_PATH
remote-everything-lan-server node list --state PATH
remote-everything-lan-server node remove --state PATH --node NODE
remote-everything-lan-server node token renew --state PATH --node NODE --node-bootstrap ABSOLUTE_PATH
remote-everything-lan-server certificate renew --state PATH [--valid-days DAYS]
remote-everything-lan-server ports repair --state PATH
remote-everything-lan-server serve --state PATH
remote-everything-lan-server device --state PATH list
remote-everything-lan-server device --state PATH invite --name NAME --node NODE [--ttl DURATION] [--qr ABSOLUTE_PATH]
remote-everything-lan-server device --state PATH renew --name NAME --node NODE [--ttl DURATION] [--qr ABSOLUTE_PATH] FINGERPRINT
remote-everything-lan-server device --state PATH grant --node NODE FINGERPRINT
remote-everything-lan-server device --state PATH revoke [--node NODE] FINGERPRINT
remote-everything-lan-server device --state PATH invitation list
remote-everything-lan-server device --state PATH invitation cancel TOKEN_HASH
```

LAN 入口是独立服务，和节点可以不在同一台机器上，只要求两者在同一局域网内。`--state` 是入口自己的状态目录（`lan.json`、入口自己的服务器证书、设备 CA、设备记录、每台节点的控制令牌都在这里），与节点的状态目录互不相干，入口不读节点状态。`init` 创建 schema 1 的 `lan.json`，生成或沿用入口身份与证书，自动选择入口端口，并以 `--host` 加该端口写下自己的 origin（客户端就拨这个地址，所以它必须与证书覆盖的主机一致）。`node add` 把一台机器记成这个入口的节点，并把它要的身份 bundle 写进 `--node-bootstrap` 指定的目录；由 Agent 把该目录送到那台机器执行 `binding add --bootstrap`，绑定才成立。`--node-id` 是那台机器 `init` 输出的 `node_id`，`--node-address` 是入口拨号用的地址，必须等于节点 `init` 时的 `--listen` 加上它的端口；`--host` 是入口自己对外的主机名或地址，客户端 Profile 的 origin 就是它加上入口端口。`init` 输出 `installation_id`、`listen_address`、`origin`、证书 SHA-256 指纹与公钥摘要，不产出二维码——邀请按设备签发，由 `device invite` 生成。`serve` 只读取持久化地址与自身状态，用自己的证书终止 TLS，并要求客户端出示它签发的设备证书：终端发出的每一个请求都落在信任层上，只有兑换邀请那一个不需要凭据，其余（含应用流量）都只对已批准设备开放——客户端在 WebView 里出示同一张证书，并在每个请求上带 `X-Remote-Everything-Node` 说明它要哪台节点。两种形态因此只差 TLS 在哪终止。

LAN 的应用**各占一个端口**：第一次 `open` 某个应用时入口让系统分配一个端口、立即监听、并把 `(节点, 应用) → 端口` 写进 `lan.json`，之后这个应用就一直在这个 origin 上（重启时按记录重新监听；端口被别人占了就丢掉这条记录，下次 `open` 重新分配一个）。一个证书覆盖入口的所有端口（客户端钉的是证书，不是 origin），每个端口后面的信任层与入口自身一致。`/__remote_everything/open` 还是控制面上带着节点头的那一个请求；端口只是把结果落到实处。

一台节点换地址后，重新执行一次 `node add` 指到新地址即可：节点按 `node_id` 原地更新，入口身份与证书都沿用现有的，客户端无需重新配对。加一台新节点同理，只是加完要重启入口才会服务它。

LAN 的邀请是操作者当面交出去的，兑换即批准，没有需要人工确认的一步；`device approve` 在 LAN 上没有意义（这条命令会被明确拒绝，而不是报一个找不到待批准设备）。邀请是**给一台节点开门**的：兑换它就把那台节点记到该设备名下，设备随后只能进这些节点；再给同一台设备开另一台节点的门，用 `device grant --node` 追加，不需要重新扫码。续期时先停 LAN 入口，执行 `certificate renew` 写入新的版本化证书/私钥并原子切换 `lan.json` 引用，再启动入口并验证；客户端钉的正是这张证书，所以必须重新执行一次 `device invite`，让它扫新载荷、以相同 `installation_id` 原子替换该 Profile 的指纹，不新建实例。入口端口即客户端 Profile 的 origin：`ports repair` 改变端口后原 Profile 全部失效，同样要重新发一次邀请。

## public：仅 Linux

这个形态只在 Linux 上运行，二进制在别的系统上直接拒绝启动：它的状态要归属 systemd unit 的账户，隧道的兜底探活是 systemd timer，443 入口通过 Linux 认领与检查。发到别处的网关部署不完成，所以它不下来。

以下命令必须以网关 systemd unit 的 `User` 账户执行，使 `0600` 状态文件与运行中的网关同属一人；先从真实 unit 读取账户，不以 root 直接运行管理命令。`init` 先于 unit 存在：Agent 必须先创建或选定该服务账户并以之执行，使初始状态文件与后续 unit 的 `User` 一致。

```text
remote-everything-gateway init --state PATH --origin HTTPS_ORIGIN
remote-everything-gateway node add --state PATH --name NAME --node-id NODE_ID --node-bootstrap ABSOLUTE_OUTPUT_DIRECTORY
remote-everything-gateway node list --state PATH
remote-everything-gateway node remove --state PATH --node NODE
remote-everything-gateway node token renew --state PATH --node NODE --node-bootstrap ABSOLUTE_PATH
remote-everything-gateway ports repair --state PATH
remote-everything-gateway tunnel renew --state PATH --node-bootstrap ABSOLUTE_OUTPUT_DIRECTORY
remote-everything-gateway serve --state PATH
remote-everything-gateway device --state PATH list
remote-everything-gateway device --state PATH approve FINGERPRINT
remote-everything-gateway device --state PATH invite --name NAME --node NODE [--ttl DURATION] [--qr ABSOLUTE_PATH]
remote-everything-gateway device --state PATH renew --name NAME --node NODE [--ttl DURATION] [--qr ABSOLUTE_PATH] FINGERPRINT
remote-everything-gateway device --state PATH grant --node NODE FINGERPRINT
remote-everything-gateway device --state PATH revoke [--node NODE] FINGERPRINT
remote-everything-gateway device --state PATH invitation list
remote-everything-gateway device --state PATH invitation cancel TOKEN_HASH
```

`init` 是公网安装身份的唯一创建者。它创建 schema 1 的 `server.json`、稳定 `installation_id`、设备 CA、隧道 CA 与 frps token，以及三个互不相同的动态 loopback 地址（`status`、`pairing`、`frps`）；`--origin` 是 443 入口对外服务的那个地址（例如 `https://remote.example.com`），写进状态后就是这份网关发出去的每条邀请指向的地址，也是每个应用 origin 的域名部分（应用主机在这里被解析出来，所以它必须是一个域名或地址本体，不带端口以外的别的东西）。**443 入口的配置与节点无关**：Caddyfile 里的上游只有 `pairing`、`frps`、`status` 三个，加节点不动它一个字——所以加一台节点只发生在网关这一侧。**DNS 要求**：为这个域名的子域准备一条通配记录（`*.<域名>` 指向入口所在主机）——应用主机是 `<app>.<节点前缀>.<域名>`，一条通配记录按 RFC 4592 覆盖这种没有更近节点存在的多级名字；证书不用通配：入口对每个应用主机按需签发。

`node add` 给这台节点做三件事：从网关自己的隧道服务器上分配一个 loopback 端口（`node_address`，就是隧道代理要发布的那个 `remotePort`）、给它签发**它自己的**控制令牌（写在网关状态目录的 `nodes/<node_id>`，一台一拍，一台机器泄露不牵连其他机器）、把交付目录写出来。输出里的 `node_address` 决定那台机器上 frpc 配置的两个值（`node_tunnel_port` 取它的端口，`node_host` / `node_port` 取节点自己的 `listen_address`），`tunnel_material_directory` 是材料位置，`tunnel_client_fingerprint` 记进运行记录。已有节点重新 `node add` 只做原地更新，隧道端口不动——那个端口是那台机器上正在跑的隧道代理发布的。

一台机器从网关里出去走 `node remove --state PATH --node <名字或 id>`：它停止服务这台节点、删掉这台节点的控制令牌、并从**每个**设备持有的节点名单里把它剔除（输出里的 `devices` 是被改到的那些设备指纹）。那台机器上的东西要操作者自己收——`binding remove <installation_id>` 停掉绑定、停掉隧道代理并删掉它的材料。删除同样要重启网关才完全生效（输出里也有 `restart_required`）。一台机器加回来时是全新的：它会拿到一个新的控制令牌，不是原来那一个。

控制令牌泄漏时走 `node token renew --state PATH --node <名字或 id> --node-bootstrap ABSOLUTE_PATH`：它给这台节点换一个新令牌，并把新令牌写进交付目录的 bundle。节点本身、它的地址、它在设备名单里的位置都不变。**这是一次带停机窗口的操作**，因为一台机器对一个网关只能持有一个令牌：顺序是（1）网关执行 token renew，（2）把交付目录送到那台机器，在那台机器上 `binding remove <installation_id>` 再 `binding add --bootstrap <目录>`，（3）重启网关。第 2 步和第 3 步之间那台节点不可达——网关手里还是旧令牌，机器手里已经是新令牌——所以这两步连着做，做完立刻验证一次。在网关重启之前，运行中的网关仍用旧令牌工作，这是刻意的：换令牌的生效点就是网关重启。它也是这台节点的令牌文件丢了或坏了时的出路——网关启动时读不到某台节点的令牌就整个起不来，而 `node token renew` 只读状态、不读令牌，所以仍然能给它签一个新的。

隧道材料分两堆，按"谁读它"分开：

- **服务器这一台**（`init` 输出中的 `frps_token_file` 与 `tunnel_ca_file`，都写在网关状态目录里）：frps 用它自己的 token 校验客户端；443 入口用隧道 CA 校验 frpc 的客户端证书。隧道 CA 私钥也留在这里，只用于签发客户端身份，从不出现在交付物里。
- **每台节点机器那一堆**（该节点交付目录里的 `frpc/`）：`frps-token`、`tunnel-client.crt.pem`、`tunnel-client.key.pem`——隧道代理要读的全部内容，没有别的。
  和每台一份的控制令牌不同，`frps-token` 是**整个网关共用**的一份：拿到它的机器可以在隧道服务器上发布自己的端口，所以交付目录要按网关级机密保管（`tunnel-client` 那对证书倒是每台一份，但它只在 443 入口那一跳用来说「我是个隧道客户端」，不区分是哪台）。

`--node-bootstrap` 指定的目录是交给那一台节点机器的**唯一**交付物，每台节点各有自己的一份。目录里 `bootstrap.json` 与 `control-token` 是节点要导入的身份，`frpc/` 是放到隧道代理那里的材料；`node add` 输出中的 `tunnel_material_directory` 就是后者的位置。目录已存在时必须与当前网关身份和 CA 完全匹配。重复执行不会替换已经签发的客户端身份，避免正在运行的隧道代理被静默换掉凭据。

隧道客户端证书到期前执行 `tunnel renew --state PATH --node-bootstrap ABSOLUTE_PATH`（针对那一台节点的交付目录）：它用同一个隧道 CA 签发新的客户端身份，替换交付目录 `frpc/` 里的那一对，并返回目录、指纹与隧道 CA 路径。这是纯网关侧操作，节点不参与，也不需要重启节点——绑定身份（安装 ID 与控制令牌）不变。把交付目录里的 `frpc/` 重新投递到那台节点机器上、重启隧道代理即可；旧身份在同一条隧道 CA 下仍然有效，所以这次替换不需要停机对时。该操作不改变端口、设备 CA 或移动客户端授权。

Agent 通过已有 SSH 或等价的加密管理通道把整个 bundle 送到节点，限制目录和私钥只允许部署账户读取，执行节点导入并比对两端 ID 后删除服务器输出副本与节点输入副本。长期材料只保留在两端状态目录；`runtime.json` 只记录路径和摘要。

组件停服后，`ports repair` 原子重分配该组件的全部监听地址并保持身份与证书（公网网关连每台节点的隧道端口一起重分配，输出里的 `nodes` 就是新的映射，要在节点机器上按它重渲染 frpc 配置并重启隧道代理）；Agent 同步运行记录、FRP 和反向代理引用后重启。**公网网关还要按新的 tunnel 地址重跑一次 frps 健康检查安装**（见下）：那个 timer 探的是每条隧道，端口搬走之后它探的就是已经不存在的地址，会一直以为隧道断了而不停重启 frps。

`invite --node` 创建 1 分钟至 24 小时有效的单事务邀请，它开的是**一台节点**的门，setup URI 里带着那个节点的 `node_id` 与名字；配对签发 pending PKCS#12；网关在 pending 期内暂存密码加密的响应，使同一设备名和密码可以从网络丢包中幂等恢复。移动客户端持证请求激活（带目标节点头）后写入 `approval_requested_at` 并等待；Agent 向用户展示设备名和完整指纹，得到确认后执行 `approve`。客户端再次调用激活路径，网关确认批准状态和那台节点的目录真实可达后原子激活并删除暂存响应。`renew` 只接受 approved 旧指纹并生成同类二维码，它不改变设备能进哪些节点（所以 `--node` 只能是该设备已经持有的那一台）；新证书也须人工批准，激活时再吊销旧证书并批准新证书。`grant --node` 给已批准设备追加一台节点，立即生效，不需要重新配对；`revoke --node` 只收回那一台，`revoke` 收回整台设备。`invitation list` 返回 hash、目标节点、设备名、证书指纹、期限和阶段，不返回 token、密码摘要或凭据；`invitation cancel` 删除未使用邀请，或同时删除其 paired-pending 授权。服务启动会清除没有任何有效邀请引用的孤儿 pending。设备 `list` 返回申请、批准、激活与证书时间，以及该设备持有的 `nodes`；`revoke` 原子吊销并立即阻止后续请求。

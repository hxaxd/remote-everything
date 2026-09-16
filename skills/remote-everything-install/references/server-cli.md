# 入口与网关 CLI

两种入口记录的是同一件事：**身份 + 具名监听**。`installation_id` 决定节点把它绑成谁，监听列表说的是它在哪些地址上服务，每条都有名字（LAN 是 `lan`；公网网关是 `status`、`pairing`、`frps`、`node_tunnel`），因为渲染模板、运行记录和操作者都是按角色而不是按位置来引用它们的。

文件因此也只差一点：`server.json` 就是这份状态本身；`lan.json` 是同一份状态再加一个 `lan` 块（节点地址、对外主机、客户端钉住的证书、访问令牌）。`ports repair` 是同一套实现——保住每条监听的名字与主机，只把端口搬走。CLI 输出仍然用具名字段（`status_listen`、`listen_address`……），部署模板与运行记录按这些名字取值，不受状态文件内部结构影响。

## LAN：Windows、Linux、macOS

```text
remote-everything-lan-server init --state PATH --node-address HOST:PORT --node-bootstrap ABSOLUTE_PATH --host HOST --name NAME [--valid-days DAYS] [--qr ABSOLUTE_PATH]
remote-everything-lan-server certificate renew --state PATH --name NAME [--valid-days DAYS] [--qr ABSOLUTE_PATH]
remote-everything-lan-server ports repair --state PATH
remote-everything-lan-server serve --state PATH
```

LAN 入口是独立服务，和节点可以不在同一台机器上，只要求两者在同一局域网内。`--state` 是入口自己的状态目录（`control-token`、`lan.json`、自己的服务器证书都在这里），与节点的状态目录互不相干，入口不读节点状态。`init` 创建 schema 1 的 `lan.json`，生成或沿用入口身份与访问令牌，自动选择入口端口，并把节点要的身份 bundle 写进 `--node-bootstrap` 指定的目录；由 Agent 把该目录送到节点执行 `binding add --bootstrap`，绑定才成立。`--node-address` 是入口拨号用的节点地址，必须等于节点 `init` 时的 `--listen` 加上它的端口；`--host` 是入口自己对外的主机名或地址，即移动客户端 Profile 的 origin。`init` 输出 `installation_id`、`listen_address`、`gateway_origin`、证书 SHA-256 指纹、setup URI 和可选二维码。`serve` 只读取持久化地址与自身状态。

节点换地址后重跑一次入口 `init` 并把 `--node-address` 指到新地址即可：入口身份、证书与访问令牌都沿用现有的，客户端无需重新配对。

续期时先停 LAN 入口，执行 `certificate renew` 写入新的版本化证书/私钥并原子切换 `lan.json` 引用，再启动入口并验证；移动客户端扫描输出载荷，以相同 `installation_id` 原子替换该 Profile 的指纹，不新建实例。入口端口即客户端 Profile 的 origin：`ports repair` 改变端口后原 Profile 全部失效，必须再执行一次 `certificate renew` 让移动客户端重扫替换。

## public：仅 Linux

以下命令必须以网关 systemd unit 的 `User` 账户执行，使 `0600` 状态文件与运行中的网关同属一人；先从真实 unit 读取账户，不以 root 直接运行管理命令。`init` 先于 unit 存在：Agent 必须先创建或选定该服务账户并以之执行，使初始状态文件与后续 unit 的 `User` 一致。

```text
remote-everything-gateway init --state PATH --node-bootstrap ABSOLUTE_OUTPUT_DIRECTORY
remote-everything-gateway ports repair --state PATH
remote-everything-gateway tunnel renew --state PATH --node-bootstrap ABSOLUTE_OUTPUT_DIRECTORY
remote-everything-gateway serve --state PATH
remote-everything-gateway device --state PATH list
remote-everything-gateway device --state PATH approve FINGERPRINT
remote-everything-gateway device --state PATH invite --name NAME --origin HTTPS_ORIGIN [--ttl DURATION] [--qr ABSOLUTE_PATH]
remote-everything-gateway device --state PATH renew --name NAME --origin HTTPS_ORIGIN [--ttl DURATION] [--qr ABSOLUTE_PATH] FINGERPRINT
remote-everything-gateway device --state PATH invitation list
remote-everything-gateway device --state PATH invitation cancel TOKEN_HASH
remote-everything-gateway device --state PATH revoke FINGERPRINT
```

`init` 是公网安装身份的唯一创建者。它创建 schema 1 的 `server.json`、稳定 `installation_id`、设备 CA、控制令牌，以及四个互不相同的动态 loopback 地址。

隧道材料分两堆，按"谁读它"分开：

- **服务器这一台**（`init` 输出中的 `frps_token_file` 与 `tunnel_ca_file`，都写在网关状态目录里）：frps 用它自己的 token 校验客户端；443 入口用隧道 CA 校验 frpc 的客户端证书。隧道 CA 私钥也留在这里，只用于签发客户端身份，从不出现在交付物里。
- **节点机器那一堆**（交付目录里的 `frpc/`）：`frps-token`、`tunnel-client.crt.pem`、`tunnel-client.key.pem`——隧道代理要读的全部内容，没有别的。

`--node-bootstrap` 指定的目录同时承载这两件事：它是交给节点机器的**唯一**交付物。目录里 `bootstrap.json` 与 `control-token` 是节点要导入的身份，`frpc/` 是放到隧道代理那里的材料；`init` 输出中的 `tunnel_material_directory` 就是后者的位置。目录已存在时必须与当前网关身份和 CA 完全匹配。重复执行 `init` 不会替换已经签发的客户端身份，避免正在运行的隧道代理被静默换掉凭据。

隧道客户端证书到期前执行 `tunnel renew --state PATH --node-bootstrap ABSOLUTE_PATH`：它用同一个隧道 CA 签发新的客户端身份，替换交付目录 `frpc/` 里的那一对，并返回目录、指纹与隧道 CA 路径。这是纯网关侧操作，节点不参与，也不需要重启节点——绑定身份（安装 ID 与控制令牌）不变。把交付目录里的 `frpc/` 重新投递到节点机器上的 `.runtime/state/frpc/<installation_id>/`、重启隧道代理即可；旧身份在同一条隧道 CA 下仍然有效，所以这次替换不需要停机对时。该操作不改变端口、设备 CA 或移动客户端授权。

Agent 通过已有 SSH 或等价的加密管理通道把整个 bundle 送到节点，限制目录和私钥只允许部署账户读取，执行节点导入并比对两端 ID 后删除服务器输出副本与节点输入副本。长期材料只保留在两端状态目录；`runtime.json` 只记录路径和摘要。

组件停服后，`ports repair` 原子重分配该组件的全部监听地址并保持身份与证书；Agent 同步运行记录、FRP 和反向代理引用后重启。

`invite` 创建 1 分钟至 24 小时有效的单事务邀请并输出 setup URI/二维码。配对签发 pending PKCS#12；网关在 pending 期内暂存密码加密的响应，使同一设备名和密码可以从网络丢包中幂等恢复。移动客户端持证请求激活后写入 `approval_requested_at` 并等待；Agent 向用户展示设备名和完整指纹，得到确认后执行 `approve`。客户端再次调用激活路径，网关确认批准状态和节点目录真实可达后原子激活并删除暂存响应。`renew` 只接受 approved 旧指纹并生成同类二维码；新证书也须人工批准，激活时再吊销旧证书并批准新证书。`invitation list` 返回 hash、设备名、证书指纹、期限和阶段，不返回 token、密码摘要或凭据；`invitation cancel` 删除未使用邀请，或同时删除其 paired-pending 授权。服务启动会清除没有任何有效邀请引用的孤儿 pending。设备 `list` 返回申请、批准、激活与证书时间；`revoke` 原子吊销并立即阻止后续请求。

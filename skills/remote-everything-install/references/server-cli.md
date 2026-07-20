# 入口与网关 CLI

## LAN：Windows、Linux、macOS

```text
remote-everything-lan-server init --state PATH --host HOST --name NAME [--valid-days DAYS] [--qr ABSOLUTE_PATH]
remote-everything-lan-server certificate renew --state PATH --name NAME [--valid-days DAYS] [--qr ABSOLUTE_PATH]
remote-everything-lan-server ports repair --state PATH
remote-everything-lan-server serve --state PATH
```

先初始化同一状态目录中的节点。`init` 创建 schema 1 的 `lan.json`，自动选择入口端口并输出 `installation_id`、`listen_address`、`gateway_origin`、证书 SHA-256 指纹、setup URI 和可选二维码。`serve` 只读取持久化地址。

续期时先停 LAN 入口，执行 `certificate renew` 写入新的版本化证书/私钥并原子切换 `lan.json` 引用，再启动入口并验证；手机扫描输出载荷，以相同 `installation_id` 原子替换该 profile 的指纹，不新建实例。

## public：仅 Linux

```text
remote-everything-gateway init --state PATH --node-bootstrap ABSOLUTE_OUTPUT_DIRECTORY
remote-everything-gateway ports repair --state PATH
remote-everything-gateway tunnel renew --state PATH --node-bootstrap ABSOLUTE_OUTPUT_DIRECTORY
remote-everything-gateway serve --state PATH
remote-everything-gateway device --state PATH list
remote-everything-gateway device --state PATH invite --name NAME --origin HTTPS_ORIGIN [--ttl DURATION] [--qr ABSOLUTE_PATH]
remote-everything-gateway device --state PATH renew --name NAME --origin HTTPS_ORIGIN [--ttl DURATION] [--qr ABSOLUTE_PATH] FINGERPRINT
remote-everything-gateway device --state PATH invitation list
remote-everything-gateway device --state PATH invitation cancel TOKEN_HASH
remote-everything-gateway device --state PATH revoke FINGERPRINT
```

`init` 是公网安装身份的唯一创建者。它创建 schema 1 的 `server.json`、稳定 `installation_id`、设备 CA、控制令牌、FRPS token、隧道 CA，以及四个互不相同的动态 loopback 地址；同时在指定绝对目录生成节点 bootstrap。bundle 只含节点所需的统一 ID、控制令牌、FRPS token、隧道 CA 证书和客户端证书/私钥，不含隧道 CA 私钥。目录已存在时必须与当前网关身份和 CA 完全匹配。

隧道客户端证书到期前，停节点 FRPC，使用新的空输出目录执行 `tunnel renew`，通过加密管理通道送到节点并再次执行节点 `init --bootstrap`。节点只在 installation ID、控制令牌、FRPS token 与隧道 CA 全部匹配时写入以新指纹命名的客户端证书/私钥；按 CLI 返回路径重渲染、重启并验证 FRPC 后，删除旧身份文件和两端 bundle 副本。该操作不改变端口、设备 CA 或手机授权。

Agent 通过已有 SSH 或等价的加密管理通道把整个 bundle 送到节点，限制目录和私钥只允许部署账户读取，执行节点导入并比对两端 ID 后删除服务器输出副本与节点输入副本。长期材料只保留在两端状态目录；`runtime.json` 只记录路径和摘要。

组件停服后，`ports repair` 原子重分配该组件的全部监听地址并保持身份与证书；Agent 同步运行记录、FRP 和反向代理引用后重启。

`invite` 创建 1 分钟至 24 小时有效的单事务邀请并输出 setup URI/二维码。配对签发 pending PKCS#12；网关在 pending 期内暂存密码加密的响应，使同一设备名和密码可以从网络丢包中幂等恢复。手机以该证书调用激活路径，网关确认节点目录真实可达后原子批准并删除暂存响应。`renew` 只接受 approved 旧指纹并生成同类二维码；新证书激活时以新指纹标记并吊销旧证书，再批准新证书，进程中断后相同 pending 证书可幂等完成剩余步骤，手机以相同 `installation_id` 替换 profile 凭据。`invitation list` 只返回 hash、期限和阶段，不返回 token、密码摘要或凭据；`invitation cancel` 删除未使用邀请，或同时删除其 paired-pending 授权；若续期只完成旧证书吊销，会先恢复旧授权再取消新身份。服务启动会清除没有任何有效邀请引用的孤儿 pending。设备 `list` 返回状态与 `certificate_expires_at`；`revoke` 原子吊销并立即阻止后续请求。

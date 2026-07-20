---
name: remote-everything-device
description: 管理 Remote Everything 手机信任。用于创建或取消公网邀请、列出和吊销公网设备、原地续期公网设备证书或 LAN 指纹，并验证授权变化。
---

读取 [server-cli.md](../remote-everything-install/references/server-cli.md)，从服务器 `runtime.json` 定位网关和状态目录。

- 配对：执行 `device invite --name <显示名> --origin <HTTPS入口> --ttl 10m --qr <绝对路径>`，把二维码或 setup URI 交给用户；不得保存或复用邀请明文。
- 邀请：用 `device invitation list` 观察未完成邀请；不再需要的邀请按 hash 执行 `invitation cancel`。
- 查看：执行 `device list`，按设备名、完整 SHA-256 指纹、状态和时间返回。
- 公网续期：对 approved 指纹执行 `device renew ... <旧指纹>`，让用户在原手机扫描；确认相同安装 ID 的新指纹 approved、旧指纹 revoked，再删除二维码和 setup URI 临时副本。
- LAN 续期：停入口，执行 `certificate renew`，重启并验证新证书；让用户扫描同安装 ID 的更新载荷，确认客户端替换指纹而不是新增 profile。
- 吊销：核对完整指纹后执行 `device revoke <指纹>`，再次列出并验证该证书访问得到 401 或 403。

---
name: remote-everything-device
description: 管理 Remote Everything 移动客户端信任。用于在两种形态下创建或取消邀请、列出和吊销设备、原地续期设备证书或入口证书，并验证授权变化。
---

读取 [server-cli.md](../remote-everything-install/references/server-cli.md)，从服务器 `runtime.json` 定位网关、状态目录和 systemd unit，从 unit 的 `User` 读取服务账户；网关 CLI（含 `device invite`）以该账户执行。root 发码会产生 gateway 读不到的邀请文件。

两种形态的准入是同一件事：设备兑换一条邀请、拿到只属于自己的证书，之后由这张证书被准入。公网入口在它前面由 443 终止 mTLS，LAN 入口自己终止；除此之外只差谁批准设备。

- 发邀请：用户可操作时执行 `device invite --name <显示名> --ttl 10m [--qr <本次邀请唯一的绝对路径>]`，交付二维码或 setup URI 并说明失效时间。不覆盖旧二维码路径，不保存或复用邀请明文。入口的 origin 在 `init` 时就写进状态了，发邀请不需要再给地址；状态变为 `approved` 后删掉二维码和 setup URI 临时副本。
- 批准：公网邀请跨网旅行，必须由人确认——客户端申请后从 `device list` 取设备名与完整指纹，用户确认后 `device approve <指纹>`。LAN 邀请是操作者当面交出去的，兑换即批准，不需要这一步。
- 邀请：`device invitation list`；取消用 `invitation cancel`（按 hash）。
- 查看：`device list`（设备名、完整指纹、状态、时间）。
- 公网续期：`device renew ... <旧指纹>`，同安装 ID 新指纹 approved、旧指纹 revoked 后删临时码。
- LAN 续期：停入口 → `certificate renew` → 重启验证，然后重新 `device invite`。客户端钉的是入口证书，证书换了就得重新发一次邀请让它重扫；同安装 ID 原地替换该 Profile，不新建实例。
- 吊销：`device revoke <指纹>`，再 list，确认该证访问为 401/403。

设备变更记入 `AGENTS.local.md`。

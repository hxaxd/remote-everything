---
name: remote-everything-device
description: 管理 Remote Everything 移动客户端信任。用于创建或取消公网邀请、列出和吊销公网设备、原地续期设备证书或 LAN 指纹，并验证授权变化。
---

读取 [server-cli.md](../remote-everything-install/references/server-cli.md)，从服务器 `runtime.json` 定位网关、状态目录和 systemd unit，从 unit 的 `User` 读取服务账户；网关 CLI（含 `device invite`）以该账户执行。root 发码会产生 gateway 读不到的邀请文件。

- 配对：用户可操作时执行 `device invite --name <显示名> --origin <HTTPS入口> --ttl 10m [--qr <本次邀请唯一的绝对路径>]`，交付二维码或 setup URI 并说明失效时间。不覆盖旧二维码路径，不保存或复用邀请明文。客户端申请后从 `device list` 取设备名与完整指纹，用户确认后 `device approve <指纹>`。状态变为 `approved` 后删掉二维码和 setup URI 临时副本。
- 邀请：`device invitation list`；取消用 `invitation cancel`（按 hash）。
- 查看：`device list`（设备名、完整指纹、状态、时间）。
- 公网续期：`device renew ... <旧指纹>`，同安装 ID 新指纹 approved、旧指纹 revoked 后删临时码。
- LAN 续期：停入口 → `certificate renew` → 重启验证；客户端扫同安装 ID 更新载荷，替换指纹而非新建 Profile。
- 吊销：`device revoke <指纹>`，再 list，确认该证访问为 401/403。

设备变更记入 `AGENTS.local.md`。

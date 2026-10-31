---
name: remote-everything-device
description: 管理 Remote Everything 客户端信任。用于创建和取消邀请、列出和批准设备、追加或吊销节点授权、续期设备及 LAN 入口证书。
---

从 [runtime.md](../remote-everything-install/references/runtime.md) 定位网关和部署账户；命令使用 [server-cli.md](../remote-everything-install/references/server-cli.md) 中的 `GATEWAY device --state PATH` 前缀。

## 邀请与准入

用户可以操作时执行 `invite --name NAME --node NODE --ttl 10m [--qr ABSOLUTE_PATH]`，交付二维码、setup URI 或邀请码及准确失效时间。邀请携带目标节点与入口信息，用户无需手填连接参数；浏览器仍需设置自己的保险箱密码。二维码用本次唯一文件名，完成准入后删除临时码和 URI 副本。

| 网关 | 准入方式 |
| --- | --- |
| public，或设置 `--require-approval` 的 LAN | 客户端兑换邀请并请求激活；从 `list` 读取设备名与完整指纹，取得用户确认后 `approve FINGERPRINT` |
| 未设置该选项的 LAN | 当面交付邀请即为批准依据，不另做人工 approve |

设备证书配对先生成 pending 记录；激活还要求目标节点目录可达。public 浏览器同样作为设备审批，指纹为 `sha256("web:" + client_id)`；是否有浏览器入口及边界见[应用信任说明](../remote-everything-app/SKILL.md#应用信任边界)，连接凭据见 [Web 连接模型](../../internal/client/webclient/README.md#browser-connections)。

## 命令与作用范围

以下均为 `device` 后的 ACTION：

| ACTION | 行为 |
| --- | --- |
| `list` | 设备名、完整指纹、状态、申请/批准/激活/证书时间及 `nodes` |
| `grant --node NODE FINGERPRINT` | 为已批准设备追加节点，即时生效，无需再配对 |
| `revoke --node NODE FINGERPRINT` | 只收回一台节点，保留设备连接 |
| `revoke FINGERPRINT` | 吊销整台设备；复核记录及该凭据访问被拒绝 |
| `invitation list` | 邀请 hash、目标节点、设备名、期限与阶段，不返回邀请明文或凭据 |
| `invitation cancel TOKEN_HASH` | 取消未使用邀请；已兑换但未激活时同时撤销 pending 授权 |
| `renew --name NAME --node NODE [--ttl DURATION] [--qr ABSOLUTE_PATH] OLD_FINGERPRINT` | 为已批准设备签发替换证书；NODE 必须是它已有权限的节点 |

邀请 TTL 为 1 分钟至 24 小时。证书配对在 pending 期保存密码加密响应，支持同设备名和密码的网络重试；激活后清除暂存响应。取消、过期与服务启动的孤儿清理共同回收未完成事务。

## 续期

设备证书续期使用上表 `renew`；保留节点权限，替换凭据完成激活后吊销旧凭据。需要审批的网关仍按准入表批准替换设备。

LAN 服务端证书续期：停入口 → `certificate renew` → 启动验证 → 重新发 `invite` 让客户端取得当前固定信息。相同 installation ID 原地替换连接；入口端口改变也按此重新发码。public 的 HTTPS 证书由其入口管理。隧道证书不属于设备凭据，按 [server-cli.md](../remote-everything-install/references/server-cli.md#节点交付与隧道材料) 或 [LAN 隧道](../remote-everything-install/references/lan-tunnel.md) 维护。

将设备变更和验证结果记入 `AGENTS.local.md`。

iOS 客户端的签名续期（免费账号 7 天循环、定时重签、报警通道与路径选择）见 [ios-signing.md](references/ios-signing.md)。

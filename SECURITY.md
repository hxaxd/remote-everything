# 安全策略 / Security Policy

[中文](#中文) · [English](#english)

## 中文

### 报告

[GitHub 私密漏洞报告](https://github.com/hxaxd/remote-everything/security/advisories/new)。不可用时开一个不含细节的公开 Issue，再约私密渠道。

目标：7 天内确认收到；14 天内初步判断或追问。披露节奏与维护者协调。

### 范围

配对与设备状态；mTLS / 指纹 / 吊销；网关→节点控制令牌；反向代理路径、Host、Cookie、WebSocket；客户端凭据与 Web 隔离；Skill / 发布链路。

**已经声明的边界，不作为漏洞受理**：LAN 形态里网关与节点之间的那段链路按可信网络对待（控制令牌与应用流量都在这张网上，节点自身的应用数据面不再另做鉴权），见 [README 安全模型](README.md#安全模型)。这不是待修的缺口而是有意的取舍：要跨不可信网络就用公网形态，那条路上离开机器的每一跳都是 TLS。想改变这个决定，请开普通 Issue 讨论。

其它问题见 [CONTRIBUTING.md](CONTRIBUTING.md)。

## English

### Reporting

[GitHub private vulnerability reporting](https://github.com/hxaxd/remote-everything/security/advisories/new). If unavailable, open a public Issue with no details, then arrange a private channel.

Target: acknowledge within 7 days; initial assessment or follow-up questions within 14 days. Coordinate disclosure timing with maintainers.

### Scope

Pairing and device state; mTLS / fingerprints / revocation; gateway→node control tokens; reverse-proxy path, Host, Cookie, WebSocket; client credentials and Web isolation; Skill / release pipeline.

**Declared boundaries, not accepted as vulnerabilities**: in LAN mode the Gateway–Node path is treated as a trusted network — the control token and application traffic both travel on it, and the node's own application data plane carries no further authentication. See the [security model](README_EN.md#security-model). That is a deliberate trade-off rather than a gap waiting to be closed: to cross an untrusted network, use public mode, where every hop that leaves a machine is TLS. To change that decision, open an ordinary Issue.

Everything else: [CONTRIBUTING.md](CONTRIBUTING.md).

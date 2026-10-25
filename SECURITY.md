# 安全策略 / Security Policy

[中文](#中文) · [English](#english)

## 中文

### 报告

通过 [GitHub 私密漏洞报告](https://github.com/hxaxd/remote-everything/security/advisories/new) 联系维护者；不可用时，先开不含漏洞细节的 Issue 约定私密渠道。目标为 7 天内确认收到、14 天内初步判断，披露时间与维护者协调。

### 范围与信任边界

受理配对、设备授权与吊销、mTLS、控制令牌、代理、客户端凭据和 Web 隔离、运维 Skill 及发布链路的问题。

- 浏览器连接的凭据、有效期、锁定、退出与应用票据，以 [Web 连接模型](internal/webclient/README.md#browser-connections) 为准。
- 应用的可信前提、Cookie 隔离限制及两种网关的浏览器入口取舍，见[应用信任边界](skills/remote-everything-app/SKILL.md#应用信任边界)。实现未遵守这些边界的问题仍属于报告范围。
- 直连 LAN 的网关→节点链路依赖受控网络；跨不可信网络使用加密隧道。拓扑与暴露面见[网络说明](skills/remote-everything-install/references/networking.md)。

其它贡献见 [CONTRIBUTING.md](CONTRIBUTING.md)。

## English

### Reporting

Use [GitHub private vulnerability reporting](https://github.com/hxaxd/remote-everything/security/advisories/new). If unavailable, open an Issue without vulnerability details to arrange a private channel. We aim to acknowledge within 7 days and assess within 14 days; coordinate disclosure with maintainers.

### Scope and trust boundaries

Reports may cover pairing, device authorization and revocation, mTLS, control tokens, proxies, client credentials and Web isolation, operational Skills, and the release pipeline.

- Browser credentials, expiry, locking, logout, and handoff tickets are defined in the [browser connection model](internal/webclient/README.md#browser-connections).
- Trusted-app requirements, Cookie isolation limits, and browser availability are defined in the [application trust boundary](skills/remote-everything-app/SKILL.md#应用信任边界). Implementation failures against these boundaries remain in scope.
- Direct LAN gateway→node traffic relies on a controlled network. Use encrypted tunnels across untrusted networks; see [network topology and exposure](skills/remote-everything-install/references/networking.md).

Other contributions: [CONTRIBUTING.md](CONTRIBUTING.md).

# 支持说明 / Support

[中文](#中文) · [English](#english)

## 中文

### 去哪里提问

- 可复现缺陷：使用 [Bug 表单](https://github.com/hxaxd/remote-everything/issues/new?template=bug_report.yml)。
- 功能建议：使用 [功能表单](https://github.com/hxaxd/remote-everything/issues/new?template=feature_request.yml)。
- 安全漏洞：按 [SECURITY.md](SECURITY.md) 私密报告。
- 贡献实现：先读 [CONTRIBUTING.md](CONTRIBUTING.md)。

### 提供哪些信息

请说明版本、移动客户端平台、节点平台、LAN/public 形态、最早失败的步骤、复现方法和已经脱敏的日志。部署问题优先提供 `runtime.py validate` 或 inspect Skill 的摘要，不要粘贴整个 `.runtime`。

公开内容中必须删除：私钥、证书包、邀请 URI、token、真实内网拓扑、不必要的公网地址、设备完整指纹和个人数据。

### 支持边界

这是社区维护的开源项目，不提供付费 SLA 或保证响应时间。维护者会优先处理安全问题、稳定复现的缺陷和影响当前正式版本的问题。第三方 Web 应用自身的业务故障，应先在其原生浏览器和本机入口复现后再判断是否属于 Remote Everything。

## English

- Reproducible bug: use the [bug form](https://github.com/hxaxd/remote-everything/issues/new?template=bug_report.yml).
- Feature proposal: use the [feature form](https://github.com/hxaxd/remote-everything/issues/new?template=feature_request.yml).
- Security vulnerability: report it privately through [SECURITY.md](SECURITY.md).
- Code contribution: read [CONTRIBUTING.md](CONTRIBUTING.md).

Include the version, mobile client platform, node platform, LAN/public topology, earliest failing layer, reproduction steps, and redacted logs. Prefer validation/inspection summaries over full runtime directories. Remove credentials, invitation URIs, tokens, unnecessary addresses, full device fingerprints, and personal data.

This is a community-maintained open-source project with no paid SLA or guaranteed response time. Security issues and reproducible defects affecting the current release take priority.

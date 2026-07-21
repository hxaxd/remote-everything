# 安全策略 / Security Policy

[中文](#中文) · [English](#english)

## 中文

### 支持范围

安全修复面向最新正式版本。项目不维护旧版本兼容分支；确认漏洞后，修复会进入新的正式版本，并在必要时给出重建、重新配对或吊销凭据的明确步骤。

### 私密报告漏洞

请使用 GitHub 的 [私密漏洞报告](https://github.com/hxaxd/remote-everything/security/advisories/new)。如果该入口暂时不可用，请只创建一个不含漏洞细节的公开 Issue，要求维护者建立私密联系方式。

报告中请包含：

- 受影响组件、版本、平台与部署形态；
- 可复现步骤或最小概念验证；
- 实际影响、攻击前提和你建议的严重级别；
- 已做的脱敏，以及是否已向其他人披露；
- 可选的修复建议。

不要提交真实私钥、PKCS#12、邀请明文、控制令牌、完整运行目录或不必要的个人数据。需要样例时，请创建一次性测试身份并在报告后吊销。

### 响应预期

- 维护者目标是在 7 天内确认收到报告；
- 在 14 天内提供初步判断或请求补充信息；
- 修复时间取决于严重度、复现稳定性和多平台验证范围；
- 修复发布前，请给维护者合理的协调披露时间。

### 重点关注范围

- 配对邀请、pending/approved/active 状态绕过；
- mTLS、证书固定、指纹注入或吊销失效；
- 网关到节点的控制令牌泄漏；
- 反向代理路径、Host、Cookie 或 WebSocket 跨应用越权；
- 移动客户端凭据存储、Web 数据隔离或更新签名绕过；
- 安装/更新/卸载 Skill 的命令注入、路径逃逸或越权删除；
- 发布流程、依赖和签名供应链风险。

不涉及安全边界的普通故障、功能建议和使用问题请使用 Issue 模板或 [SUPPORT.md](SUPPORT.md)。

## English

### Supported versions

Security fixes target the latest stable release. The project does not maintain legacy compatibility branches. A fix may require a new release, rebuild, re-pairing, or credential revocation when that is the safest response.

### Private reporting

Use GitHub's [private vulnerability reporting](https://github.com/hxaxd/remote-everything/security/advisories/new). If it is temporarily unavailable, open a public Issue containing no vulnerability details and ask the maintainers to establish a private channel.

Include the affected component/version/platform/topology, reproducible steps or a minimal proof of concept, impact and prerequisites, disclosure status, and an optional remediation idea. Never send production private keys, PKCS#12 files, invitation secrets, control tokens, full runtime directories, or unnecessary personal data.

The project aims to acknowledge reports within 7 days and provide an initial assessment or request for more information within 14 days. Remediation time depends on severity and the cross-platform verification required. Please allow coordinated disclosure before publishing details.

Ordinary bugs, feature requests, and support questions belong in the public Issue forms or [SUPPORT.md](SUPPORT.md).

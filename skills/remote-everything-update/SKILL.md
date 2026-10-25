---
name: remote-everything-update
description: 升级已部署的 Remote Everything。用于核验发布资产，替换目标组件，保留身份和授权，并验证原有连接及应用。
---

1. 按 [runtime.md](../remote-everything-install/references/runtime.md) 确定目标组件、owner、复用关系、状态和原有设备授权。仅更新请求涉及的组件。
2. 按 [releases.md](../remote-everything-install/references/releases.md) 核验同一目标标签资产。状态或命令有破坏性变化时，按 remove/install 重建目标范围；普通升级保留 ID、控制令牌、CA、设备凭据与端口。
3. 将产物下载到运行目录外，检查摘要、目标平台及 [服务/FRP 模板](../remote-everything-install/references/templates.md)。public 的入口变更另按 [reverse-proxy.md](../remote-everything-install/references/reverse-proxy.md)，LAN 隧道另按 [lan-tunnel.md](../remote-everything-install/references/lan-tunnel.md) 验证。
4. 停止受影响的依赖方，再停目标组件：节点侧 FRPC→node，直连 LAN 入口→node，服务器 gateway/LAN→FRPS；按反序启动。Windows 残留进程按模板参考的身份匹配规则处理。用同目录临时文件原子替换二进制，保留旧文件至验证结束，失败恢复。
5. 复验原有目录、启停、应用代理和授权；只在已有测试凭据时检查 revoked 拒绝。检查 [FRPS 定时器](../remote-everything-install/references/frps-healthcheck.md) 是否需按目标模板或当前节点地址重装。
6. 证书剩余不超过 30 天时，按 [device Skill](../remote-everything-device/SKILL.md) 或 [隧道证书说明](../remote-everything-install/references/server-cli.md#节点交付与隧道材料) 执行对应续期。
7. 客户端来源与签名按 [mobile-clients.md](../remote-everything-install/references/mobile-clients.md) 处理；Android 升级须更高 versionCode 且签名一致。验证原连接保留可用，更新 runtime 的 release、摘要和结果，清除临时旧文件。

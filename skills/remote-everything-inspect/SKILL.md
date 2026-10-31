---
name: remote-everything-inspect
description: 只读巡检 Remote Everything。用于核对组件归属、端口、证书、隧道、设备授权和应用链路，定位连接故障。
---

1. 按 [runtime.md](../remote-everything-install/references/runtime.md) 验证记录，核对 executable、摘要、完整参数、PID/启动时间、管理器和集成 owner。
2. 从状态读取实际监听与节点地址，命令输出字段按 [server-cli.md](../remote-everything-install/references/server-cli.md#节点增删与令牌续换) 对照。
3. 按部署形态核对设备入口、证书有效期和每条节点路径：public 读 [HTTPS 入口](../remote-everything-install/references/reverse-proxy.md) 与 [健康检查](../remote-everything-install/references/frps-healthcheck.md)，LAN 隧道读 [专用参考](../remote-everything-install/references/lan-tunnel.md)。证书剩余不超过 30 天时记录续期需求。
4. 从客户端入口逐层验证目录、控制、Cookie、WebSocket 和应用代理；核对设备的节点名单及实际可达范围。连接异常按 [troubleshooting.md](references/troubleshooting.md) 分类，给出最早失败层、证据与下一步。
5. 把确认的实例事实记入 `AGENTS.local.md`；恢复动作交给 update/device/app/remove 等对应 Skill，巡检不修改运行状态。

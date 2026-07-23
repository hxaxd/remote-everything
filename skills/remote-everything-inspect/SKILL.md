---
name: remote-everything-inspect
description: 只读检查 Remote Everything。用于巡检、排障、确认拓扑，核对组件身份、动态端口、TLS、隧道、设备授权与应用链路。
---

读取 [runtime.md](../remote-everything-install/references/runtime.md)、[node-cli.md](../remote-everything-install/references/node-cli.md) 和 [server-cli.md](../remote-everything-install/references/server-cli.md)。

1. 验证 `runtime.json`，核对二进制摘要、完整参数、PID/启动时间、管理器、定义、日志与集成所有者。
2. 从组件状态读取实际监听地址；核对进程身份和端口，不猜固定端口。
3. LAN 核验证书有效期、SAN、指纹及移动客户端入口；public 核对 443 路由、FRPC/FRPS、隧道客户端证书有效期、设备 CA、叶指纹头和设备记录。任何运行证书剩余不超过 30 天时明确返回续期需求。
4. 从入口依次验证目录、控制、Cookie、WebSocket、节点探活和应用代理，定位最早失败层。
5. 返回预期、实际、证据和故障层；不改状态。

改状态：device / app / update / remove+install。结论里要留的事实写入 `AGENTS.local.md`。

---
name: remote-everything-inspect
description: 只读检查 Remote Everything。用于巡检、排障、确认拓扑，核对组件身份、动态端口、TLS、隧道、设备授权与应用链路。
---

读取 [runtime.md](../remote-everything-install/references/runtime.md)、[node-cli.md](../remote-everything-install/references/node-cli.md) 和 [server-cli.md](../remote-everything-install/references/server-cli.md)。

1. 验证 `runtime.json`，核对二进制摘要、完整参数、PID/启动时间、管理器、定义、日志与集成所有者。
2. 从组件状态读取实际监听地址；核对进程身份和端口，不猜固定端口。
3. LAN 核验证书有效期、SAN、指纹及移动客户端入口；public 核对 443 路由、FRPC/FRPS、隧道客户端证书有效期（每台节点一条隧道：材料在那台机器的 `state/frpc/<node_id>/`，与网关侧那台的交付目录里的一份必须一致；`node list` 给出每台的 `node_address`，frpc 配置里的 `node_tunnel_port` 就是它的端口）、设备 CA、叶指纹头和设备记录，并核对 frps 健康检查 timer `enabled/active`、单元 ExecStart 指向的脚本真实存在且不含未渲染占位符、脚本里的 `FRPS_ADDRESS` 等于当前 `frps_listen`、`TUNNEL_ADDRESSES` 覆盖当前每一台节点的 `node_address`（`ports repair` 或加删节点之后必须重装，否则探的是一批已经不存在的地址）、最近一次 service 运行结果与 `frps-health.log` 无持续 FAIL。任何运行证书剩余不超过 30 天时明确返回续期需求。
4. 从入口依次验证目录、控制、Cookie、WebSocket、节点探活和应用代理，定位最早失败层；多台节点时逐台验证（每个请求的节点头决定去哪台），并核对设备记录里的 `nodes` 与该设备实际能到的节点一致。
5. 返回预期、实际、证据和故障层；不改状态。

改状态：device / app / update / remove+install。结论里要留的事实写入 `AGENTS.local.md`。

# AGENTS.md

本仓库里给 Agent 用的索引。步骤在 `skills/`，当前机器上的事实在 `AGENTS.local.md`。

## 阅读顺序

1. 本文件  
2. `AGENTS.local.md`（有的话）  
3. 对应 `skills/*/SKILL.md` 及其 `references/`

`skills/` 放在仓库里直接用即可，不要求装进编辑器；要装也可以。

## `AGENTS.local.md`

本地笔记本（gitignore）。记拓扑、installationId、runtime 路径、端口、应用、设备、产物路径、坑、流水。示例：[`AGENTS.local.example.md`](AGENTS.local.example.md)。

## 架构

```
一个 Node = 一台机器 = 一个全局唯一的 node_id（换地址、修端口都不变）
一个 Gateway 可以有零台或多台 Node，空网关也能运行（每台：node_id + 操作者给的名字 + 网关拨它的地址）
每个 Gateway 绑定 = 一个 installationId = 手机一条路（一个 Profile，手动切换）
设备 = 每个 Gateway 一张证书 + 它能进的节点名单（设备 × 网关 × 节点）
```

设备信任在入口判断，节点只接收网关绑定。节点登记、撤销、控制令牌、请求选路和应用寻址见 [server-cli.md](skills/remote-everything-install/references/server-cli.md)；拓扑选择见 [networking.md](skills/remote-everything-install/references/networking.md)，共享节点和多网关入口见 [multi-computer.md](skills/remote-everything-install/references/multi-computer.md)。

## Skill

| 任务 | 目录 |
|------|------|
| 安装 / 重建 | `skills/remote-everything-install/` |
| 升级 | `skills/remote-everything-update/` |
| 清理 | `skills/remote-everything-remove/` |
| 设备信任 | `skills/remote-everything-device/` |
| 应用 | `skills/remote-everything-app/` |
| 巡检 | `skills/remote-everything-inspect/` |

详见 [`skills/README.md`](skills/README.md)。

运行目录：`.runtime/`（外部二进制在 `.runtime/bin/`）。实例细节只写 `AGENTS.local.md`。

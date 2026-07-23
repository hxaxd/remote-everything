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
一台电脑 = Node + Gateway（LAN 或 public）= 一个 installationId = 手机一个 Profile
多台电脑 = 多个 installationId / Profile，手动切换
```

公网多机可共用 Caddy，各 gateway 分路由。没有「一个安装下选多节点」。

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

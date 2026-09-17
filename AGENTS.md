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
一个 Gateway 服务它旗下的一台或多台 Node（每台：node_id + 操作者给的名字 + 网关拨它的地址）
每个 Gateway 绑定 = 一个 installationId = 手机一条路（一个 Profile，手动切换）
设备 = 每个 Gateway 一张证书 + 它能进的节点名单（设备 × 网关 × 节点）
```

Gateway 与 Node 同局域网（LAN 入口）或经隧道（公网网关），两者可以不在同一台机器上。两种 Gateway 都自行产出身份 bundle（每台节点一份），由 Agent 送到那台节点执行 `binding add` 注册——节点只认身份，不碰 Gateway 的证书与隧道材料。**信任只在 Gateway 判定**：真正看到客户端证书的是入口那一跳。手机先选节点再选路，请求用 `X-Remote-Everything-Node` 说明去哪台（例外是 `/__remote_everything/nodes`：它问"我手里有哪几台"，所以不带节点头）。节点是加进来也是能撤出去的：`node add` / `node remove` / `node token renew`（令牌泄漏时换一条），一台机器的来去只发生在 gateway 这一侧。一个网关加节点不动 Caddyfile 一个字；一台 Caddy 承载多个网关要各自一个域名、各一份 site block，模板一次只渲染一个，共用需要手工合并（README/SKILL 里 1:1 的部署是默认形态）。

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

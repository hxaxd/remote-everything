# 运行记录

每台节点和公网服务器分别使用项目内 `.runtime/`：

```text
.runtime/
├── bin/
├── config/
├── state/node/ 或 state/server/
├── logs/
└── runtime.json
```

`runtime.json` 使用严格 schema 1。用 `python skills/remote-everything-install/scripts/runtime.py init ...` 创建；用 `put` 更新组件、依赖或集成；用 `verify` 写入验收结果；用 `validate` 检查。工具拒绝旧/未知字段并原子替换文件。

机器契约和样例分别为 `assets/runtime.schema.json`、`assets/runtime.minimal.json` 与 `assets/runtime.full.json`。

组件同时记录 `expected` 和 `observed`：可执行文件 SHA-256、完整参数、工作目录、监听地址、PID、启动时间、管理器、定义、日志与验证结果。依赖记录固定版本、来源、路径和摘要。集成记录 `managed`、真实 owner、definition、insertion、restore 与 verification；移除流程据此决定删除对象或仅撤销插入片段。

组件 ID：

| ID | 含义 |
|---|---|
| `node` | 节点核心 |
| `lan` | 局域网入口 |
| `frpc` | 节点公网隧道 |
| `gateway` | Linux 公网网关 |
| `frps` | 服务器隧道端 |
| `reverse-proxy` | 443 入口，仅无现有入口时作为项目组件 |

节点侧管理器记录为 Windows 用户计划任务、macOS 用户 LaunchAgent 或 Linux `systemd-user`，只承诺部署用户登录期间在线；Linux 服务器组件记录为系统级 `systemd`。现有反向代理、防火墙作为 `integrations` 记录；已有远程组网也作为 `managed:false` 的外部集成记录，项目不修改或移除它。项目自行下载的 FRP、Caddy 和发布资产作为 `dependencies` 记录。敏感值只保存在权限受限的状态文件，运行记录保存其路径。

先从组件初始化结果取得 `installation_id` 和动态地址，再创建运行记录。启动前写期望状态；启动后写观测状态。敏感值仅记录受限文件路径，不写内容。

# 运行记录与组件归属

运行目录通常为项目内 `.runtime/`，实际路径以 runtime 记录为准：

```text
.runtime/
├── bin/
├── config/
├── state/node/、state/lan/、state/server/
├── state/frpc/<installation_id>/<node_id>/
├── logs/
└── runtime.json
```

网关和节点状态分开管理；相同机器被多个网关服务时复用同一个节点，不复制节点身份。每条“节点 × 网关”隧道有独立 FRPC 配置、材料、日志、进程和管理器名称，按两个 ID 隔离；FRPC 在节点机器上运行，FRPS 在网关机器上运行。

共享节点或 Caddy 只能有一个负责生命周期的 owner：拥有者记录 `managed:true`，其它部署记录复用关系，不在卸载时停掉或删除共享对象。复用入口中的本站点配置、防火墙规则等用 integrations 的精确 insertion/restore 表达。

## 记录内容

`runtime.json` 使用严格 schema 1；契约和样例在 `assets/runtime.schema.json`、`runtime.minimal.json`、`runtime.full.json`。用 `scripts/runtime.py init/put/verify/validate` 创建、修改和验证，工具原子替换文件并拒绝未知字段。

- components：唯一组件 ID、managed、可执行文件及 SHA-256、完整参数、工作目录、日志、管理器 ID/definition、expected、observed、verification。观测包含 PID、启动时间和监听地址。
- dependencies：固定版本、来源、路径与摘要。
- integrations：真实 owner、definition、managed、精确插入内容、恢复方法及验证。

组件角色为 node、lan、frpc、gateway、frps、reverse-proxy；同一记录内重复角色使用可区分的组件 ID。管理器命名及平台安装位置见 [templates.md](templates.md#服务管理器)。服务使用部署账户执行，Linux 系统组件以 unit 的 `User` 为准；初始化时即选定该账户，避免状态文件权限不一致。

先取得初始化身份与动态地址，再写启动期望；启动后写观测和验证。凭据只保存在受限状态文件，记录只保存路径和摘要。维护或卸载以已验证的记录界定对象，不能从程序名推断进程归属。

---
name: remote-everything-app
description: 管理 Remote Everything 节点应用。用于发现、登记、更新、启停、验证或移除明确指定的本地 Web 应用。
---

读取 [node-cli.md](../remote-everything-install/references/node-cli.md)，从 `.runtime/runtime.json` 定位节点可执行文件、状态目录和当前入口。

## 已知应用

`apps/` 收录已深度适配的应用（确定 ID、definition.json 模板、NOTES.md 接入要点）。目标应用命中条目时，按模板填占位符登记并逐条执行接入要点；不命中时按下面的通用流程。新适配验证通过后，把确定 ID、模板与接入要点固化进 `apps/` 再交付。

## 登记

1. 检查应用启动命令、工作目录、loopback `proxy_url` 与停止方式；从应用现有标识与元数据推导稳定 ID 和显示名称，登记后启动并验证。只有用户明确要求保持停用时才不启动；不让用户填写技术字段。探活地址从 `proxy_url` 派生。
2. 将严格应用定义写入权限受限的临时 JSON 文件，执行 `remote-everything-control app set --state <state/node> --file <文件>`，登记后销毁临时文件。
3. 执行 `app list` 核对定义；需要启用时调用本地控制接口 `start`，等待 `status` 返回 `ready`。
4. 从实际手机入口访问应用，验证路径、查询参数、Cookie 和 WebSocket 行为，并与已登记应用逐一复验共存。同一安装实例的应用共享 origin、Cookie、Web Storage 和 Service Worker 信任域，因此只登记同等可信的应用；应用不得占用 `/__remote_everything` 路径、不得用根 scope Service Worker 接管其他应用。网关会丢弃应用返回的 `RemoteEverythingApp` 路由 Cookie。

## 更新

读取当前启用状态；已启用应用依次执行 `stop → app set → start → status`。相同定义的 `changed:false` 视为成功。

## 移除

依次执行 `stop` 和 `app remove`，确认应用端口与进程树释放、目录不再返回该应用。重复移除的 `changed:false` 视为成功。

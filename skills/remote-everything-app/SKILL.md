---
name: remote-everything-app
description: 管理 Remote Everything 节点应用。用于发现、登记、更新、启停、验证或移除明确指定的本地 Web 应用。
---

读取 [node-cli.md](../remote-everything-install/references/node-cli.md)，从 runtime 定位节点、状态目录和当前入口。

## 应用信任边界

只接入可信、无恶意的应用及插件。独立 origin 隔离页面与本地存储，但 Cookie 不按端口隔离，当前布局不提供恶意应用之间的完整隔离。

| 入口 | 浏览器策略与原因 |
| --- | --- |
| LAN（包括无域名隧道） | 不提供浏览器客户端：入口与应用同主机、不同端口，无法以端口隔离入口 Cookie |
| public | 允许但不推荐：独立子域与主机绑定凭据保护入口，但应用脚本仍可能写父域 Cookie，干扰同父域其它应用 |

网关过滤应用流量中的内部凭据并约束服务器下发的 Cookie；具体处理见 [Web Cookie 实现](../../internal/client/webclient/README.md#public-application-cookie-boundary)。原生客户端另有[网页会话隔离](../../clients/behavior/README.md)，不改变按节点授权的粒度。

## 登记

目标命中 `apps/<id>/` 时使用其 definition 模板和 NOTES；其它应用按 [patterns.md](references/patterns.md) 选择接入方式。

1. 检查启动命令、工作目录、loopback 代理地址和停止方式，从现有标识推导稳定 ID 与元数据。
2. 按节点 CLI 的字段约束生成受限临时 JSON，执行 `remote-everything-control app set --state PATH --file FILE`，核对 `app list` 后删除临时文件。
3. 除用户要求保持停用外，通过控制接口 `start`，等待 `status` 为 ready。
4. 从目标客户端验证路径、查询、Cookie、WebSocket 和与其它应用共存。资源及跳转使用相对路径或应用自身 origin；协议保留路径和路由规则见 [server-cli.md](../remote-everything-install/references/server-cli.md#网关端口与应用路由)。

新增适配经验证后，将稳定 ID、模板与接入要点保存到 `apps/`；实例值保留在运行记录。

## 更新

读取启用状态；已启用应用按 `stop → app set → start → status` 更新，`changed:false` 为成功。应用二进制在外部重装或升级后也需停止并重新启动，单纯重复登记不会替换正在运行的旧进程。

## 移除

依次 `stop`、`app remove`，确认端口和受管进程树释放，目录不再返回该应用；重复移除的 `changed:false` 为成功。

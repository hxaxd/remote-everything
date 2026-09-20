---
name: remote-everything-app
description: 管理 Remote Everything 节点应用。用于发现、登记、更新、启停、验证或移除明确指定的本地 Web 应用。
---

读取 [node-cli.md](../remote-everything-install/references/node-cli.md)，从 `.runtime/runtime.json` 定位节点可执行文件、状态目录和当前入口。

## 应用信任边界

**只接入可信、无恶意的应用及插件；这是部署前提。** 当前系统不提供不可信应用之间的完整安全隔离。Cookie 的作用范围是「协议 + 主机」，**不按端口分隔**，三种客户端形态因此不同：

- **公网网关：提供 Web 客户端，但不推荐。** 每个应用是网关域下的一个子域（`https://<appid>.<节点前缀>.<网关域名>`），会话 Cookie 以 `__Host-` 前缀下发——浏览器强制这个名字只能由设置它的那个主机读写，别的来源既写不进去也覆盖不了——网关还会剥掉应用自己服务器下发的 Cookie 的域范围。残留风险是应用页面里的脚本仍可写父域 Cookie（`Domain=<父域>`）来注入或干扰会话，所以只应在接入可信应用时使用。
- **局域网网关：不提供 Web 客户端。** 应用与入口是同一个主机的不同端口，而端口不分隔 Cookie，一个应用页面与入口共享同一个 Cookie 罐：它能写入口会收到的 Cookie，也能读入口任何没标 HttpOnly 的 Cookie。这个形态因此不给浏览器入口，只服务持证书的设备。
- **原生客户端**：另有按网关、节点、应用划分的网页会话隔离，其存储隔离不改变按节点授权的规则，也不构成恶意应用安全沙箱。

不得把独立应用地址、设备认证或常规功能验证当作应用无恶意或完整隔离的证明。

## 已知应用

`apps/` 收录已深度适配的应用（确定 ID、definition.json 模板、NOTES.md 接入要点）。目标应用命中条目时，按模板填占位符登记并逐条执行接入要点；不命中时按下面的通用流程。新适配验证通过后，把确定 ID、模板与接入要点固化进 `apps/` 再交付。

## 登记

1. 检查应用启动命令、工作目录、loopback `proxy_url` 与停止方式；从应用现有标识与元数据推导稳定 ID 和显示名称，登记后启动并验证。只有用户明确要求保持停用时才不启动；不让用户填写技术字段。探活地址从 `proxy_url` 派生。
2. 将严格应用定义写入权限受限的临时 JSON 文件，执行 `remote-everything-control app set --state <state/node> --file <文件>`，登记后销毁临时文件。
3. 执行 `app list` 核对定义；需要启用时调用本地控制接口 `start`，等待 `status` 返回 `ready`。
4. 从 Android、iOS 或 HarmonyOS 的真实移动客户端入口访问应用，验证路径、查询参数、Cookie 和 WebSocket 行为，并与已登记应用逐一复验共存。**每个应用在自己的 origin 上被服务**（公网网关 `https://<appid>.<节点前缀>.<网关域名>`、局域网网关 `<网关地址>:<每应用端口>`），浏览器同源策略限制跨应用的页面及 LocalStorage、IndexedDB 访问，Cookie 的适用范围另见上面的应用信任边界。因此应用的资源与跳转请一律用相对路径（或自身 origin），别硬编码网关的控制 origin：控制 origin 上已不再提供应用路径，一律 404。应用不得占用 `/__remote_everything` 路径。网关会丢弃应用返回的 `RemoteEverythingApp` 路由 Cookie，并由网关自己为节点写上正确的那个。

## 更新

读取当前启用状态；已启用应用依次执行 `stop → app set → start → status`。相同定义的 `changed:false` 视为成功。**应用自己的二进制在外部被换过（重装包、升级全局 CLI）之后也必须走这一条**：注册不会因此重启它，不 stop+start 就还在跑旧进程。

## 移除

依次执行 `stop` 和 `app remove`，确认应用端口与进程树释放、目录不再返回该应用。重复移除的 `changed:false` 视为成功。

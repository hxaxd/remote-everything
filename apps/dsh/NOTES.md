# DeepSeek Harness (DSH) 接入要点

确定 ID：`dsh`。目标：在移动客户端随时查看与使用 DeepSeek Harness 网页控制台。

1. **服务启动**：使用 `dsh.exe web` 子命令启动 Web UI 服务。
2. **回环监听与免弹窗**：启动参数必须包含 `--host 127.0.0.1` 确保仅监听回环地址，并传入 `--no-open` 避免在节点后台拉起服务时在宿主机唤起默认浏览器。
3. **信任白名单 (`--trusted-host`)**：`dsh web` 内置浏览器信任保护围栏，对 `/api` 接口校验请求 Authority，不在名单里的主机一律 `403 forbidden`（**只有 API 会 403，页面外壳照常渲染**，所以症状是"界面能开、一操作就报错"）。`{{TRUSTED_HOST}}` 填的是**这个应用自己的 origin 主机名**（公网形态 `<appid>.<节点前缀>.<网关域名>` 与 `...:443`），它同时决定 `adapter.js` 里 `CANONICAL_HOST` 的值——渲染时用同一份替换表填入，两处不会不一致。
4. **谁来对齐 Host：adapter，不是重登记**（2026-09-19 定案）。节点**故意**把入口的 Host 原样传给应用（`application_proxy.go`：酒馆那类比对 Origin/Host 防 DNS rebinding 的应用要靠它），所以手机从**任何别的名字**进来（LAN 入口的地址与端口、又一个新入口），Host 就不是 DSH 名单里的那个。以前的办法是「换入口就 `stop → app set → start` 重登记」，现在改成在 `adapter.js` 的 `onRequest` 里把 `Host`／`Origin`／`Referer` 都说成 `CANONICAL_HOST`：**应用永远只听见它认识的那个名字，入口怎么变都不用重登记**。为此 `internal/nodeadapter` 的 `__req.setHeader("Host", …)` 必须真的改到上游请求（Go 里 Host 不在 header map 上，而在 request 本体），该行为有测试钉住（`adapter_test.go`）。验证方式（本机、不需要手机）：`curl -H "Cookie: RemoteEverythingApp=dsh" -H "Host: <LAN 地址:端口>" http://127.0.0.1:58627/api/checkCleanIp` —— 修好前 403，修好后 401（401 是 DSH 自己的登录态，说明它已在应答）。
5. **端口分配**：从节点现状选择未被其他登记应用占用的端口，同时填入启动参数 `--port` 与 `proxy_url`。LAN 入口给应用分配的对外端口是**首次打开时定下来**的（公网形态按名字推导，稳定），所以 adapter 里不要假设它等于 `--port`。
6. **停止方式**：`stop_command` 留空，由 `remote-everything-control` 自动接管并回收整棵进程树。
7. **验证**：从移动客户端或入口（携带 `RemoteEverythingApp=dsh`）打开 DSH 首页与会话列表，确认静态资源、API 与 WebSocket 正常工作；与现有登记应用逐一复验共存。若 DSH 在响应里写绝对地址（登录后如果页面自己跳到公网域名，即是这种），那属于响应侧，可在 `onResponse` 处理，目前未发现。
4. **端口分配**：从节点现状选择未被其他登记应用占用的端口，同时填入启动参数 `--port` 与 `proxy_url`。
5. **停止方式**：`stop_command` 留空，由 `remote-everything-control` 自动接管并回收整棵进程树。
6. **验证**：从移动客户端或入口（携带 `RemoteEverythingApp=dsh`）打开 DSH 首页与会话列表，确认静态资源、API 与 WebSocket 正常工作；与现有登记应用逐一复验共存。

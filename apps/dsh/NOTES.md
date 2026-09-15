# DeepSeek Harness (DSH) 接入要点

确定 ID：`dsh`。目标：在移动客户端随时查看与使用 DeepSeek Harness 网页控制台。

1. **服务启动**：使用 `dsh.exe web` 子命令启动 Web UI 服务。
2. **回环监听与免弹窗**：启动参数必须包含 `--host 127.0.0.1` 确保仅监听回环地址，并传入 `--no-open` 避免在节点后台拉起服务时在宿主机唤起默认浏览器。
3. **信任白名单 (`--trusted-host`)**：`dsh web` 内置浏览器信任保护围栏，对 `/api` 接口校验请求 Authority。经 Remote Everything 入口远程访问时，须按部署形态传入实际入口主机名（public 传公网网关主机名及 `<host>:443` 两种形式，LAN 传节点入口主机名与端口形式），确保移动端通过入口访问时不被 403 拦截；入口主机名在登记时填入 `{{TRUSTED_HOST}}`，不固化在模板中。
4. **端口分配**：从节点现状选择未被其他登记应用占用的端口，同时填入启动参数 `--port` 与 `proxy_url`。
5. **停止方式**：`stop_command` 留空，由 `remote-everything-control` 自动接管并回收整棵进程树。
6. **验证**：从移动客户端或入口（携带 `RemoteEverythingApp=dsh`）打开 DSH 首页与会话列表，确认静态资源、API 与 WebSocket 正常工作；与现有登记应用逐一复验共存。

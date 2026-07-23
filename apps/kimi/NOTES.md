# KimiWeb 接入要点

确定 ID：`kimi`。目标：移动客户端从目录点开后不再询问 server token。

1. **必须 `--foreground`**：默认后台 daemon 会脱离节点进程树——节点会把主进程退出当作应用退出并退避重启，真正的 daemon 逃出进程组，`stop` 失效。
2. **单例**：本机已有实例时再 `run` 只打印已运行并退出。登记前先 `kimi server kill`（它也是 `stop_command`），或明确复用现有实例。
3. **端口**：kimi 默认端口可能撞上节点首选端口 58627；显式选固定端口写入 `proxy_url`，并避开其他已注册应用。
4. **`--allowed-host`（最易漏）**：Kimi 对 WebSocket 会同时核对 Origin 与 Host。公网网关必须把入口 Host（IP 或域名）原样传到应用，不能改成 `127.0.0.1`；`--allowed-host` 必须覆盖每个会从目录进入的入口主机。LAN 形态 Host 含端口，登记后从移动客户端入口实测。
5. **token**：首次启动后从节点日志 `<state>/logs/kimi.log` 取 `Kimi server: ...#token=<TOKEN>` 写入 `launch_fragment`。token 持久，重启不变；`kimi server rotate-token` 后必须同步更新 `launch_fragment`。
6. **验证**：带路由 Cookie 与 `Authorization: Bearer <TOKEN>` 经节点代理访问 `/api/v1/auth`，返回 200 且 `ready:true`；再从真实移动客户端入口打开，确认不再出现 token 输入框。

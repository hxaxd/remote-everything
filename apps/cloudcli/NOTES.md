# CloudCLI 接入要点

确定 ID：`cloudcli`。目标：在移动客户端随时查看 Claude Code 会话。

1. **生产构建**：`npm run build` 产出 `dist/`（前端）和 `dist-server/`（后端），一步即可。后端内嵌前端静态文件，不依赖外部 Vite dev server。
2. **端口注入**：Windows 启动器 `{{CLOUDCLI_LAUNCHER}}` 接收 `{{PORT}}` 参数并设为 `SERVER_PORT` 环境变量，后端以此端口启动。`{{CMD_BINARY}}` 使用目标系统的 `cmd.exe`，工作目录由 `{{CLOUDCLI_DIR}}` 注入。
3. **无鉴权**：服务端不做访问控制，安全性由 Remote Everything 的 mTLS 设备鉴权兜底。不要暴露给公网。
4. **停止**：`stop_command` 留空，节点回收整棵进程树（Node.js 主进程 + 子进程）。
5. **验证**：从真实移动客户端入口打开 CloudCLI 首页，确认能看到已有的 Claude Code 会话列表；点进一个会话确认消息历史可加载。

# OpenCode 接入要点

确定 ID：`opencode`。目标：在移动客户端上使用 OpenCode 的全部功能——会话管理、实时流式对话、Diff 审查、文件浏览。

## 1. 二进制获取

OpenCode 是全局 CLI 工具，安装方式多样：

| 平台 | 命令 |
|------|------|
| npm (推荐) | `npm i -g opencode-ai@latest` |
| Scoop (Windows) | `scoop install opencode` |
| Chocolatey (Windows) | `choco install opencode` |
| Homebrew (macOS/Linux) | `brew install opencode` |
| Arch Linux | `pacman -S opencode` |

部署时 `{{OPENCODE_BINARY}}` 指向安装后的 `opencode`（或 `opencode.exe`），`{{OPENCODE_DIR}}` 设为会话数据持久化的目录（默认为用户主目录下的项目路径）。

> **运行时依赖**：OpenCode 基于 Bun，npm 包已自包含运行时，不需要单独安装 Bun。

## 2. 端口注入

`--port {{PORT}}` 显式指定固定端口。注意避开节点首选端口 58627 和已注册的其他应用端口。

`--hostname 127.0.0.1` 限制只监听 loopback——安全性由 Remote Everything 的 mTLS 设备鉴权兜底，不暴露给公网。

## 3. 无鉴权

OpenCode Web 模式本身不做访问控制（`OPENCODE_SERVER_PASSWORD` 可选）。Remote Everything 接入沿用 CloudCLI 的策略：不设密码，安全性完全依赖 mTLS 设备鉴权。如果部署环境有特殊要求，可在 `opencode.json` 的 `server` 块中配置密码，或设置 `OPENCODE_SERVER_PASSWORD` 环境变量。

## 4. 浏览器自动打开问题

`opencode web` 启动时可能打开默认浏览器，且 1.18.3 没有 `--no-browser` 参数。节点只管理 OpenCode 自身的进程树，不承诺关闭已经存在的浏览器进程；这个本地页面不会改变远程入口的安全边界。

## 5. 停止

`stop_command` 留空。节点回收整棵进程树（Bun 主进程 + 子进程），无需单独停止命令。

## 6. 反向代理注意事项

- **Host 头**：代理链路原样保留 Host 头。OpenCode 使用 Hono 作为 HTTP 框架，默认不严格校验 Host 头，但登记后需从移动客户端入口实测，确认 SSE 流和静态资源加载正常。
- **SSE 流**：OpenCode Web 使用 Server-Sent Events 推送实时对话流。Gateway 代理必须禁用响应缓冲，否则流式输出会被囤积。
- **无 WebSocket**：OpenCode Web 模式只用 SSE + HTTP，不涉及 WebSocket 升级，代理配置比 SillyTavern 简单。
- **静态资源**：所有前端静态资源由 `opencode web` 内嵌提供，不依赖外部 CDN 或 `app.opencode.ai` 代理。

## 7. 配置文件

OpenCode 的 `opencode.json`（项目根目录或 `~/.opencode/`）中的 `server` 块可覆盖端口和主机名。命令行参数优先于配置文件。部署时如果同时存在 `opencode.json`，确保其中没有冲突的 `server.port` 或 `server.hostname` 设置。

## 8. 验证

1. 从节点日志确认 `opencode web` 启动成功，端口监听在 `127.0.0.1:{{PORT}}`。
2. `curl http://127.0.0.1:{{PORT}}` 返回 200 且包含 OpenCode Web 首页 HTML。
3. 从真实移动客户端入口打开 OpenCode 首页，确认：
   - 页面正常加载（CSS/JS 无 404）
   - 能看到已有会话列表（或空状态页）
   - 新建会话后 SSE 流式对话正常
   - Diff 预览和文件浏览器可用
4. 与已登记应用逐一复验共存（共享网关 origin、客户端 Web 数据按应用隔离）。

## 9. 同类工具对比

OpenCode 与 CloudCLI 同属"终端编程 Agent + Web UI"模式，接入 Remote Everything 的方式高度一致：

| 维度 | CloudCLI | OpenCode |
|------|----------|----------|
| Agent 本体 | Claude Code (Anthropic, 闭源) | OpenCode (MIT 开源) |
| LLM 支持 | Claude 系列 | 75+ Provider (Claude/OpenAI/Gemini/本地) |
| 运行时 | Node.js (npm build 产出) | Bun (全局二进制) |
| Web 启动 | `npm run build` → 独立 server | `opencode web` 一条命令 |
| 鉴权方式 | 无，靠 mTLS | 无（可选密码），靠 mTLS |
| 流式协议 | 需确认 | SSE |

**接入经验**：此类工具的 Web UI 接入 Remote Everything 遵循统一模式——`proxy_url: http://127.0.0.1:{{PORT}}` + 无内置鉴权 + 进程树回收停止。关键验证点是 SSE/WebSocket 流式传输是否被代理缓冲阻断。

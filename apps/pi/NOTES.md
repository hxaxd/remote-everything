# Pi Coding Agent 接入要点

确定 ID：`pi`。目标：在移动客户端上使用 Pi Coding Agent 的完整 Web 对话界面。

Web UI 使用 `wgnr-pi` 1.5.2，通过 WebSocket 连接 `pi --mode rpc` 子进程。接入必须使用固定版本的独立安装目录和本目录的 `launcher.mjs`，不得修改全局包源码。

## 1. 安装与固定版本

Pi Coding Agent 使用已验证的 0.73.1：

```bash
bun install -g @mariozechner/pi-coding-agent@0.73.1
```

为 `wgnr-pi` 创建独立目录，并强制使用嵌套依赖布局：

```bash
npm install --prefix "{{PI_WEB_DIR}}" --install-strategy=nested --ignore-scripts --save-exact wgnr-pi@1.5.2
```

`wgnr-pi` 1.5.2 按自身目录读取 `marked` 和 `dompurify`。普通全局或提升式安装可能让首页返回 200，但两个 `/lib/*` 静态资源返回 404。项目运行物必须位于 `.runtime/bin/`，而 Express 的 `sendFile` 在 Windows 上会忽略路径中的点目录；`launcher.mjs` 因此为固定的 1.5.2 版本安装进程内兼容层，并把可读取范围限制在 wgnr-pi 包目录。不要手改 `server.js`。

部署时填充：

- `{{NODE_BINARY}}`：Node.js 的绝对路径。
- `{{PI_LAUNCHER}}`：本目录 `launcher.mjs` 的绝对路径。
- `{{WGNR_PI_SERVER}}`：独立安装目录中 `node_modules/wgnr-pi/server.js` 的绝对路径。
- `{{PI_BINARY}}`：`pi` 或 `pi.exe` 的绝对路径。
- `{{PI_HOME}}`：运行用户主目录的绝对路径。
- `{{PI_WORKDIR}}`：Pi 可以读写和执行命令的目标工作目录。
- `{{PORT}}`：未被节点和其他应用占用的动态端口。

## 2. 凭据

先在同一运行用户下启动交互式 `pi`，执行 `/login` 并选择 Provider。API key 和 OAuth 凭据由 Pi 写入 `~/.pi/agent/auth.json`，不得写入模板、启动参数、`runtime.json` 或项目文件。

不要使用 Windows `set` 或 `setx` 登记 Pi 密钥。`set` 只影响当前终端及其子进程，`setx` 只影响之后启动的进程并把密钥扩散到整个用户环境；长期运行的 Remote Everything 节点不会自动获得后来设置的值。

`auth.json` 不存在、为空或不含目标 Provider 时，先完成登录再启动 Pi Chat。Agent 不索取、不打印也不代为提交密钥。

## 3. 启动与网络边界

`launcher.mjs` 在加载第三方服务器前确定性设置：

- `WGPI_HOST=127.0.0.1`，禁止绕过 Remote Everything 从局域网直连。
- `WGPI_PORT={{PORT}}`，避免固定端口冲突。
- `WGPI_CWD={{PI_WORKDIR}}`，修复 Windows 下会话目录接口因 `CWD` 未定义而返回 500。
- `WGPI_PI_BIN={{PI_BINARY}}`，不依赖计划任务继承的 PATH。
- `HOME={{PI_HOME}}`，让 wgnr-pi 在 Windows 上找到 Pi 会话目录。

启动器同时核验包名和版本，仅对 wgnr-pi 包目录内的静态文件替换 `sendFile` 行为；版本变化会拒绝启动，必须先完成更新验证。

wgnr-pi 自身不鉴权，因此回环监听是强制安全边界。`proxy_url` 必须与 `WGPI_PORT` 一致且只能使用 `127.0.0.1`。

## 4. 进程与协议

节点启动 Node.js 加载 `launcher.mjs`，启动器在同一进程中加载 wgnr-pi；wgnr-pi 再启动 `pi --mode rpc`。停止时节点回收整个进程树，`stop_command` 留空。

浏览器与 wgnr-pi 使用 `/ws` WebSocket，wgnr-pi 与 Pi 使用基于标准输入输出的 JSON-RPC。入口必须透传 WebSocket 升级。

## 5. 验证

1. `app list` 中定义已替换全部占位符，命令、启动器、服务器、Pi 二进制和工作目录均为绝对路径。
2. 监听地址只能是 `127.0.0.1:{{PORT}}`，本机局域网地址访问同一端口必须失败。
3. 以下请求都必须返回 200，不能只验证首页：
   - `/`
   - `/lib/marked.umd.js`
   - `/lib/purify.js`
   - `/api/sessions`
4. 节点日志出现 `pi health: CONNECTED`，浏览器 `/ws` 可以完成握手并收到初始状态。
5. 从真实移动客户端创建会话并发送一条消息，确认模型鉴权、流式响应、会话恢复和停止后进程回收正常。
6. 与所有已登记应用逐一复验共存，确认共享网关 origin 下 Web 数据仍按应用隔离。

## 6. 更新

先在临时目录安装目标版本并重复上述 HTTP、WebSocket 和真机验证。验证通过后替换独立安装目录并更新模板版本；不要直接升级正在使用的全局包，也不要保留针对旧版本源码的就地修改。

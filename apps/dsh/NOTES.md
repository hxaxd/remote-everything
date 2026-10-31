# DeepSeek Harness（DSH）接入要点

固定应用 ID：`dsh`。应用定义见 [definition.json](definition.json)，请求适配见 [adapter.js](adapter.js)。

## 服务定义

- 使用 `dsh web` 启动，传入 `--host 127.0.0.1`、`--no-open` 和选定的 `--port`；`proxy_url` 使用同一个回环端口。实际地址、路径和启用状态从 runtime 与应用注册表读取。
- `{{TRUSTED_HOST}}` 填应用自己的 origin 主机名；公网形态为 `<appid>.<节点前缀>.<网关域名>`。同一替换值用于启动参数 `--trusted-host`（主机名及 `:443` 形式）和 adapter 的 `CANONICAL_HOST`。
- LAN 对外应用端口由入口首次打开时分配，不等于 DSH 的监听端口。
- `stop_command` 留空，由节点回收受管进程树。登记、更新与启停顺序按[应用 Skill](../../skills/remote-everything-app/SKILL.md)执行。

## 认证与入口适配

### 首页要求认证

出现 `dsh web authentication required; reopen the URL printed by dsh web.` 时，对比直连 DSH 与经过节点代理的认证结果：当前启动令牌能直连登录、代理无 Cookie 请求却返回 401，说明要检查 adapter 是否取得了本次令牌。

DSH 可能先开放端口，等插件加载结束后才打印带 `?token=` 的登录 URL。`onStart` 未读到令牌时返回 `false`，节点会重新读取**本次启动**的输出，直到钩子完成；端口可连不能代替这个条件。节点的通用钩子约定见[接入模式](../../skills/remote-everything-app/references/patterns.md#适配器adapterjs)。

### Cookie 与重启

首次请求注入启动令牌，DSH 返回会话 Cookie 并重定向到干净路径。adapter 从 `Set-Cookie` 记住当前进程实际签发的 Cookie 名；请求携带该 Cookie 后停止注入令牌，否则会反复触发登录重定向。

DSH 重启会更换登录凭据。客户端仍可能持有旧 `dsh-auth-*` Cookie，因此必须匹配当前 Cookie 名，不能仅凭 Cookie 中存在这个前缀就跳过认证。adapter 的令牌状态随进程生命周期重建。

### API 返回 403

界面能打开、API 却返回 `403 forbidden` 时，检查 DSH 的请求 Authority 白名单。节点保留入口传来的 Host；adapter 将 `Host`、`Origin`、`Referer` 统一到 `CANONICAL_HOST`，因此新增或切换网关入口无需重登记 DSH。

Go 的上游 Host 位于 `request.Host`，`__req.setHeader("Host", …)` 必须修改该字段，普通 header map 不起作用。相关回归见 [adapter_test.go](../../internal/node/nodeadapter/adapter_test.go)。

## 依赖一致性

界面已加载但新建会话失败时，先检查**最近一次启动**的服务日志。若出现插件 `failed to import` 或 `does not provide an export named`，逐项核对：

1. 实际运行的 DSH 安装位置及其 `package.json` 版本。
2. 报错插件声明的 `peerDependencies` 与实际解析到的依赖版本，包括模型、会话持久化、标题和运行环境等依赖。
3. 对不满足声明的 peer 包修正安装；Bun 全局安装下可将这些包显式固定到声明要求的版本。不能仅凭主程序版本正确，就认为整套插件依赖已对齐。

依赖或二进制更新后重新启动 DSH，确认该次启动不再有导入错误，再复验创建会话。本机软件版本与安装位置按共享能力索引查询；部署结果和证据路径写入 `AGENTS.local.md`、runtime。

## 验收

1. 新客户端经节点代理进入：无 Cookie 请求完成令牌登录重定向，携带新 Cookie 后首页返回 200，且静态资源正常加载。
2. 保留客户端旧 Cookie，重启 DSH 后再次进入：能取得新登录态，不出现 401 或连续登录重定向。
3. 从实际客户端读取会话列表、选择工作区并创建会话，核对 API 与 WebSocket；仅看到页面外壳不算功能通过。

诊断请求中的节点地址和路由信息按[节点 CLI](../../skills/remote-everything-install/references/node-cli.md#应用定义与控制)读取，令牌、Cookie 和带令牌的 URL 不写入本文件。

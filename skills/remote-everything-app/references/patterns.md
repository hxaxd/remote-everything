# 应用接入模式

`apps/` 中的模板只保存稳定 ID、用户可见元数据、占位符和经过验证的启动形态。实例端口、用户名、安装路径、凭据和部署地址不得固化进模板。

## 原生 Web 服务

应用自身可以显式设置监听地址和端口时，定义直接启动其可执行文件：

- 强制监听 `127.0.0.1`。
- 从节点现状选择未占用端口并同时填入启动参数与 `proxy_url`。
- 使用绝对命令和工作目录。
- 应用不鉴权时只能依赖 Remote Everything 入口，不能额外监听局域网地址。

DSH 和 SillyTavern 属于这一类。

### 适配器（adapter.js）

原生 Web 服务若在启动时把动态凭据打印到 stdout（如 DSH 的随机 token），在 `definition.json` 旁放一个 `adapter.js`：节点注册时自动发现并连同定义一起登记，运行时按 onStart / onRequest / onResponse / onStop 四个钩子执行（goja，纯 Go）。钩子能读启动 stdout 与跨钩子的 key-value 状态，能改请求的 query/header 与响应的 header/状态码。约束：

- `app list` 与控制接口不输出 adapter 源码；源码存于 `apps.json` 与 `adapter.js`，用 `app adapter ID` 单独查看。
- 适配器失败（语法错误、钩子异常）不阻断应用，只写日志。
- `app set` 重登记后 adapter 源码变化会触发应用重启以加载新适配器。
- 钩子提取凭据依赖「凭据在端口打开前打印」的时序，接入前先从日志确认这一点。

## CLI Agent Web 包装器

Web UI 需要启动 CLI Agent 子进程时，额外验证：

- CLI 可执行文件使用绝对路径，不依赖服务管理器继承的 PATH。
- 仅支持环境变量的第三方 Web UI 通过项目启动器注入端口、回环地址、主目录和工作目录，不使用 `setx` 等全局持久环境变量。
- Provider 凭据只使用 CLI 官方凭据存储或受限状态文件，不进入应用定义、启动参数、日志和 Git。
- 停止应用时整棵进程树必须释放。
- 除首页外，还要验证会话 API、静态资源以及 SSE 或 WebSocket 实时链路；端口探活不能代替功能探活。

当前没有现存条目，按上述检查项适配，验证通过后再入库。

## 交付检查

每个模板至少验证定义严格解析、回环监听、动态端口、启停幂等、移动端真实会话和与其他应用共存。模板交付时同步提交 `definition.json`、`NOTES.md` 及所需的无凭据启动器；实例事实只写入 `AGENTS.local.md`。

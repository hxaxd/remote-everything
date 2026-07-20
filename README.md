# 远程万物（Remote Everything）

> 我们的项目不需要人类去阅读，只需要 Agent 去阅读就可以了。

Agent 首先读取 `AGENTS.md`，再按任务进入对应分区：

- `clients/android/`：Android 客户端源码、测试与构建配置
- `nodes/windows/`、`nodes/linux/`、`nodes/macos/`：三平台节点核心与测试
- `server/lan/`：三平台局域网服务
- `server/public/`：Linux 公网服务
- `skills/`：安装、升级、应用、设备、巡检和移除操作
- `.github/`：持续集成与仓库检查

本地实例信息在 `AGENTS.local.md`，交付计划在 `PLAN.md`；两者均不入库。安全边界、构建命令和事故约束以 `AGENTS.md` 为准。

节点安装后允许应用目录为空，不预装或隐式选择默认应用。2.0 不兼容旧结构，破坏性变化通过移除后干净重装处理。

同一安装实例内登记的 Web 应用共享一个浏览器 origin 和存储信任域，不提供应用间隔离；只登记同等可信的应用。项目保留 `/__remote_everything` 路径与 `RemoteEverythingApp` 路由 Cookie，网关阻止应用覆盖该 Cookie。

Windows、Linux 与 macOS 节点只负责已注册应用的进程、探活端口、本地控制/反向代理；公网形态另行运行 frpc 隧道，不包含文件管理或终端能力。

节点侧组件属于部署用户的登录会话，只承诺该用户登录期间可用。无服务器的异地访问只复用用户已经选择并建立的远程组网，项目不选择或安装组网产品。

公网反向代理由 Agent 根据服务器现状接入；节点运行目录不包含 Caddy。

Android 客户端只有一个通用构建。安装 Agent 生成二维码或初始化链接；用户只需扫描或粘贴，不向 APK 注入部署配置或凭据。

## License

[Apache-2.0](LICENSE)

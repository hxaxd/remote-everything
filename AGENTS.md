# AGENTS.md — Agent 工作规则

Android 通用客户端经局域网入口或公网 mTLS 网关，远程控制 Windows、Linux、macOS 节点上明确注册的本地 Web 应用。项目只给 Agent 读：文档、目录、脚本保证可发现、可执行、可验证。

目录：`clients/android/` Android 客户端；`nodes/{windows,linux,macos}/` 节点（测试在各自 `tests/`）；`server/lan/` 局域网入口；`server/public/` Linux 公网网关；`internal/` 共享核心包；`apps/` 已适配应用的确定 ID、模板与接入要点；`skills/` 操作流程；`.github/` 仓库自动化。

## 实例记录

`AGENTS.local.md`（gitignore 不入库）是运维事实来源：部署形态、节点地址、组件与端口、`runtime.json` 位置、服务引用、已登记应用、已批准设备、凭据位置、清理历史。每次变更后更新；与现实不符先只读核实修正再操作。

## 架构契约

- 节点只维护已注册应用的进程与探活端口，在持久化 loopback 地址提供应用目录、启停与反向代理；只承诺部署用户登录期间可用（Windows 计划任务 / macOS LaunchAgent / Linux 用户级 systemd）。公网模式由 Agent 启动 FRPC，局域网模式运行 `server/lan`。
- 节点允许空应用目录；不预装、不隐式选择默认应用；接入按 `remote-everything-app` skill 执行并验证；已适配应用见 `apps/`。
- 局域网入口不鉴权客户端，客户端固定服务端证书指纹，入口用内部令牌访问节点。
- 公网网关：单次邀请 → pending 证书 → 人工核对设备名与完整指纹批准 → 激活，此后 mTLS 加设备记录鉴权；控制令牌只在网关到节点链路。

## 约定

- 安装、配置、更新、清理按 `skills/` 完成并适配目标机器现状；运行物进项目 `.runtime/`，外部引用记录进 `runtime.json`；FRP 等外部依赖由 Agent 获取校验后放入 `.runtime/bin/`。
- 异地且无公网服务器：先与用户对齐是否已有远程组网，有则复用；没有则推荐免费虚拟组网 **Tailscale**。互通后按局域网形态部署，项目不维护组网产品本身。
- 每种形态只占一个对外高端口；不占 80/443（服务器侧仅 443+22）；Caddy 类大件不进节点。
- 说明集中在本文件、`README.md`、`README_EN.md` 与各 `SKILL.md`；安全边界只强不弱，改动保持最小。

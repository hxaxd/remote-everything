# AGENTS.md

Agent 通用规则。运维事实（部署拓扑、实例地址、凭据、已批准设备）全部进 `AGENTS.local.md`，本文件不记录具体部署。

## 文件分工

| 文件 | 用途 | 谁写 |
|------|------|------|
| `AGENTS.md` | 架构、目录、约定、本地可验证环境 | 项目维护，不记实例 |
| `AGENTS.local.md` | **当前环境的运维事实**：拓扑、地址、端口、`runtime.json` 位置、已登记应用、已批准设备、操作历史 | 每次变更后更新 |
| `skills/*/SKILL.md` | 可执行操作流程 | 按需扩展 |
| `skills/*/references/*.md` | CLI 契约、模板、部署形态参考 | 供 Skill 引用 |
| `apps/*/` | 已适配应用的确定 ID、模板、接入要点 | 新适配验证后固化 |
| `README.md` / `README_EN.md` | 中英文用户说明 | 项目维护 |

Agent 接手时：先读 `AGENTS.md` → 再读 `AGENTS.local.md` 了解当前环境 → 按任务匹配对应 Skill。

当前有意让 still 不需要安装进去，因为大部分工作应该在本目录进行完成。如果说用户需要安装可以安装。

## 目录

```
clients/contracts/   三端共享的协议契约与测试夹具
clients/{android,ios,harmony}/   Android / iOS / HarmonyOS 原生移动客户端
nodes/{windows,linux,macos}/   节点（各自 tests/）
server/lan/          局域网入口
server/public/       Linux 公网网关
internal/            共享核心包
apps/                已适配应用
skills/              操作流程
.github/             仓库自动化
```

## 架构

```
一台电脑 = 一个 Node + 一个 Gateway（LAN 或 public）
        = 一个 installationId
        = 移动客户端上一个 Profile

多台电脑 = 多个独立的 installationId = 移动客户端上添加多个 Profile 手动切换。
不需要也不提供"一个安装实例下选多节点"的中间层。
```

- **Node**：在用户电脑上以 loopback 代理已注册应用，提供目录、启停与反向代理。仅承诺用户登录期间可用（Windows 计划任务 / macOS LaunchAgent / Linux 用户级 systemd）。
- **LAN 入口**：同网或组网内直连。服务端不鉴权客户端，客户端固定服务端证书指纹。入口用内部令牌访问节点。
- **Public 网关**：单次邀请 → pending 证书 → 人工核对设备名与完整指纹批准 → 激活，此后 mTLS + 设备记录鉴权。控制令牌只在网关到节点链路。
- **Caddy**：公网形态下统一收 443，按 SNI/路径分发到各 gateway 端口。多台电脑时各自 gateway 共享同一个 Caddy，各占独立路由。
- **移动客户端**：Android、iOS、HarmonyOS 使用同一协议和产品结构，各自采用原生实现；同一时间一个活跃 Profile，支持多 Profile 存储和切换。
- **路由 Cookie**：网关用全源共享的 `RemoteEverythingApp` cookie 把 API 请求路由到正确的应用后端。

## 约定

- 安装、配置、更新、清理一律走 `skills/`，不凭记忆操作。
- 运行物进 `.runtime/`，外部依赖放入 `.runtime/bin/`。FRP 等由 Agent 获取校验。
- 每种形态只占一个对外高端口。不占 80/443（服务端仅 443 + 22）。Caddy 不进节点。
- 节点允许空应用目录；不预装、不隐式选默认应用。
- 三端客户端的协议、安全语义和测试夹具以 `clients/contracts/` 为准；平台实现不得放宽证书校验、响应解析或 Web 数据隔离。
- 应用接入按 `remote-everything-app` skill 执行。
- 异地且无公网服务器：先对齐是否已有远程组网，有则复用；没有则推荐 Tailscale 后按 LAN 部署。
- 安全边界只强不弱。改动保持最小。

# 贡献指南 / Contributing

[中文](#中文) · [English](#english)

## 中文

安全问题走 [SECURITY.md](SECURITY.md)。

### 目录

| 路径 | 内容 |
|------|------|
| `clients/` | Android / iOS / HarmonyOS，共享协议在 `clients/contracts/` |
| `nodes/` | Windows / Linux / macOS 节点 |
| `server/lan/`、`server/public/` | 局域网入口、公网网关 |
| `internal/` | Go 共享核心 |
| `apps/` | 已适配应用的定义与接入说明 |
| `skills/` | 安装 / 更新 / 设备 / 应用等操作说明 |
| `.github/workflows/` | CI 与发布定义 |

自己机器上的部署记录在本地 `AGENTS.local.md`。Agent 侧摘要见 [AGENTS.md](AGENTS.md)。

### 本地命令

整仓校验：

```powershell
./scripts/release-local.ps1 -Mode Validate
```

### PR

从 `main` 拉分支。模板在 `.github/PULL_REQUEST_TEMPLATE.md`。许可：[Apache-2.0](LICENSE)。

## English

Security: [SECURITY.md](SECURITY.md).

### Layout

| Path | Contents |
|------|----------|
| `clients/` | Android / iOS / HarmonyOS; shared contracts in `clients/contracts/` |
| `nodes/` | Windows / Linux / macOS nodes |
| `server/lan/`, `server/public/` | LAN entry, public gateway |
| `internal/` | Shared Go core |
| `apps/` | Adapted app definitions and notes |
| `skills/` | Install / update / device / app procedures |
| `.github/workflows/` | CI and release definitions |

Deploy notes for your own machine live in local `AGENTS.local.md`. Agent-oriented summary: [AGENTS.md](AGENTS.md).

### Local commands

Full-repo check:

```powershell
./scripts/release-local.ps1 -Mode Validate
```

### PR

Branch from `main`. Template: `.github/PULL_REQUEST_TEMPLATE.md`. License: [Apache-2.0](LICENSE).

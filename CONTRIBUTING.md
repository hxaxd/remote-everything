# 贡献指南 / Contributing Guide

[中文](#中文) · [English](#english)

感谢你愿意改进 Remote Everything。项目同时包含移动客户端、三平台节点、LAN/public 入口、部署 Skills 和已适配应用；小而完整、可验证的改动最容易被审阅和合并。

## 中文

### 开始之前

- 使用 GitHub Issue 先搜索是否已有相同问题。
- 安全漏洞不要创建公开 Issue，按 [SECURITY.md](SECURITY.md) 私密报告。
- 大型功能、协议变化、新依赖或安全边界变化，请先创建功能议题并对齐方案。
- 小型缺陷、测试、文档和明确的局部重构可以直接提交 PR。
- 参与项目即表示同意遵守 [行为准则](CODE_OF_CONDUCT.md)。

### 仓库地图

| 路径 | 内容 |
|---|---|
| `clients/` | Android、iOS、HarmonyOS 移动客户端与共享协议契约 |
| `nodes/` | Windows、Linux、macOS 节点 |
| `server/lan/` | 局域网入口 |
| `server/public/` | Linux 公网网关 |
| `internal/` | Go 共享核心 |
| `apps/` | 已适配应用的固定定义与验证说明 |
| `skills/` | 安装、更新、巡检、设备和应用操作流程 |
| `.github/workflows/` | 可选持续集成与发布定义 |

架构、安全边界和目录约定见 [AGENTS.md](AGENTS.md)。本地实例事实属于 `AGENTS.local.md`，不得提交。

### 开发环境

- Go 版本以 [`go.mod`](go.mod) 为准。
- Android 使用 JDK 17 和仓库内 Gradle Wrapper。
- iOS 使用项目声明的 Xcode/Swift 版本。
- HarmonyOS 使用项目声明的 DevEco Studio、HarmonyOS SDK 与 Hvigor 版本。
- Python 脚本使用 Python 3，不依赖仓库外的本地秘密或固定端口。

提交前优先运行统一的本地门禁：

```powershell
./scripts/release-local.ps1 -Mode Validate
```

也可以按改动范围运行其中的定向检查：

```bash
# Go 共享代码与服务端
gofmt -l internal server nodes
go vet ./...
go test ./...

# Android
cd clients/android
./gradlew :app:testDebugUnitTest :app:lintDebug :app:assembleDebug

# Skills 与部署资产（在仓库根目录）
python skills/validate.py
python -m unittest \
  skills/remote-everything-install/scripts/test_runtime.py \
  skills/remote-everything-install/scripts/test_render.py \
  skills/remote-everything-install/scripts/test_validate_deployment.py \
  skills/remote-everything-install/scripts/test_inspect_443.py
```

节点测试还需要在目标操作系统运行 `nodes/<platform>/tests/`。iOS 使用 XcodeGen 生成工程后执行 `xcodebuild test` 与静态分析；HarmonyOS 使用 DevEco Studio 配置 HarmonyOS 6.1.1(24) SDK，完成 Hvigor type check、测试和 HAP 构建。仓库中的工作流是可选远端入口，不替代本地门禁。

### 设计与安全要求

- 改动保持最小，不顺手重写无关模块。
- 不增加旧协议、旧状态或旧安装包兼容分支；破坏性变化提升 schema/协议版本并更新重建流程。
- LAN 证书固定、public mTLS、人工指纹批准、严格 JSON 解码、同源限制和 Web 数据隔离只能加强，不能放宽。
- 协议变化必须更新 `clients/contracts/` 的 Schema/fixture，并让 Go、Kotlin、Swift、ArkTS 对同一夹具得出一致结果。
- 不提交证书、私钥、口令、token、`.runtime/`、`AGENTS.local.md`、`local.properties`、调试安装包或真实部署地址。
- 日志、截图和测试夹具必须脱敏；设备指纹、安装 ID 与公网地址也应按问题需要最小披露。
- 新依赖必须说明用途、许可证、体积、维护状态和为什么系统库不能完成。

### 文档要求

- 用户可见功能同时更新 `README.md` 与 `README_EN.md`，章节和事实保持同步。
- 部署行为变化同时更新对应 Skill、reference、模板、验证器和运行记录 schema。
- 新适配应用放入 `apps/<id>/`，包含稳定 ID、定义模板和真实移动客户端验收说明。
- 不把当前环境的运维事实写入公共文档。

### 提交 PR

1. 从最新 `main` 创建聚焦分支。
2. 一个 PR 解决一个问题；不要混入格式化全仓库或无关重命名。
3. 填写 PR 模板，说明动机、行为变化、安全影响和验证证据。
4. 确认所有新增代码有正向、失败和边界测试。
5. 保持提交历史可读；维护者可能在合并时 squash。
6. 你对提交内容负责，包括 AI 辅助生成的代码和文档；提交前必须理解、测试并确认许可证来源。

除非另有明确声明，提交到本项目的贡献按 [Apache-2.0](LICENSE) 许可。

## English

Thank you for contributing. Remote Everything spans native mobile clients, nodes on three desktop operating systems, LAN/public gateways, deployment Skills, and app adapters. Focused changes with reproducible evidence are the easiest to review.

### Before opening work

- Search existing Issues first.
- Report vulnerabilities privately through [SECURITY.md](SECURITY.md), never in a public Issue.
- Discuss large features, protocol changes, new dependencies, and security-boundary changes in a feature Issue before implementation.
- Small fixes, tests, documentation, and clearly scoped refactors may go straight to a PR.
- Follow the [Code of Conduct](CODE_OF_CONDUCT.md).

### Expectations

- Keep changes minimal and avoid unrelated rewrites.
- Do not add legacy compatibility branches. Version breaking contracts and update the rebuild path.
- Never weaken certificate pinning, mTLS, manual fingerprint approval, strict response decoding, same-origin controls, or per-app Web data isolation.
- Protocol changes must update shared schemas/fixtures and pass equivalent Go, Kotlin, Swift, and ArkTS contract tests.
- Never commit credentials, private deployment state, real secrets, local configuration, or build artifacts.
- Redact logs and screenshots. Explain the purpose, license, size, and maintenance status of every new dependency.
- Keep `README.md` and `README_EN.md` synchronized for user-visible changes.

Run the checks listed in the Chinese section above and the platform-specific tests for every affected target. Fill in the PR template with motivation, scope, security impact, and exact verification. Contributors remain responsible for understanding and validating AI-assisted work.

Unless explicitly stated otherwise, contributions are submitted under the [Apache License 2.0](LICENSE).

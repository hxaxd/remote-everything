# 参与贡献

## 开发环境

- Windows + Go + JDK 17+ + Android SDK（客户端构建）；Ubuntu 24.04 服务器（全链路测试，可选）。
- 先读 `AGENTS.md`（硬性规则与事故教训）和 `PLAN.md`（路线图与测试基线），再动手。

## 提交前自检

- `windows-control` 与 `server/gateway`：`gofmt -l .` 无输出、`go vet ./...`、`go test ./...`。
- Android：`android/gradlew.bat :app:assembleDebug`（先跑 `configure-clients.ps1` 或手工准备 `android/agent-remote.properties`，格式见 `configure-clients.ps1`）。
- 绝不提交：令牌、PKCS#12、私钥、`agent-remote.properties`、`local.properties`、真实服务器地址。CI 的 secrets 关卡会拦，但请别依赖它。

## 规则

- PR 必须 CI 全绿（go / android / shellcheck / secrets 四路）。
- 改动保持最小：不顺手重构、不格式化无关文件。
- 安全边界（mTLS、Bearer、本地令牌、公网 403）只能加强不能削弱；削弱类改动直接拒收。
- 新增被控应用接入示例欢迎；改变架构边界的改动请先在 issue 讨论。

## 版本号

- Android：`versionCode` 每次发版 +1，`versionName` 语义化（修复 bump patch，功能 bump minor，架构变更 bump major），在 `android/app/build.gradle.kts` 修改。
- 发版同时更新 `PLAN.md` 中对应里程碑状态。

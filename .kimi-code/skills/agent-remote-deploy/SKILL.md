---
name: agent-remote-deploy
description: Agent Remote 上线流程：本地验证→部署→全链路测试→实机验证的固定顺序
whenToUse: 当用户要求部署、上线、发布、把改动同步到服务器或 Windows 时
arguments:
  - target
---

执行上线（目标：$target，缺省 = 本次全部改动）。实例信息从 `AGENTS.local.md` 读取，不存在时向用户索要。

固定顺序，不得跳步：

1. 本地验证（按改动范围）：`gofmt -l .` / `go vet` / `go test`（windows-control、server/gateway）；Python `compile(...)` 语法检查；`gradlew.bat :app:assembleDebug`。全绿才继续。
2. 记录线上现状（运行中文件的哈希/版本），作为回滚依据。
3. 部署：scp 到服务器临时路径 → 校验（`caddy validate`、`sshd -t`）→ 就位 → 按序 reload/restart：先 Windows 控制程序，再 status 服务，Caddy 最后 reload；enrollment 仅在自身变更时重启。
4. 服务端全链路测试：`PUBLIC_HOST='<服务器>' python3 test_enrollment_pkcs12.py`（先 scp 上服务器再执行）。
5. 实机验证：目录刷新 → 启动/停止 → 进入 → 边缘菜单；同时观察 Windows 无周期性终端闪窗。

任何一步失败：停止后续步骤，报告失败点与回滚建议，等用户指示，不擅自重装整套环境。

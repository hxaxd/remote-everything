# 远程万物（Remote Everything）

> 我们的项目不需要人类去阅读，只需要 Agent 去阅读就可以了。

Agent 首先读取 `AGENTS.md`，再按任务进入对应分区：

- `clients/android/`：Android 客户端、构建配置与客户端脚本
- `nodes/windows/`：Windows 节点控制程序与节点脚本
- `server/`：云端网关、隧道、注册服务与部署脚本
- `skills/`：巡检、审批、接应用、上线流程及执行参考
- `.github/`：持续集成与仓库检查

本地实例信息在 `AGENTS.local.md`，交付计划在 `PLAN.md`；两者均不入库。安全边界、构建命令和事故约束以 `AGENTS.md` 为准。

## License

[Apache-2.0](LICENSE)

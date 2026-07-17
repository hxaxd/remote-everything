# Agent 远程（Agent Remote）

用手机远程控制你 Windows 电脑上的本地 AI 应用（默认 Kimi Code）：看状态、远程启动/停止、全屏使用。新设备用审批码接入，全链路 mTLS。

## 它能做什么

- 手机 App 里看电脑在不在线、应用在没在跑
- 一键远程启动 / 停止电脑上的应用
- 在手机上全屏使用应用的 Web 界面
- 多应用接入：Kimi Code、SillyTavern 酒馆，以及任何「监听 127.0.0.1 的本地 Web 服务」
- 设备接入人工审批，吊销即时生效

## 怎么用（你不需要懂技术）

这个项目的安装、部署、运维**全部设计为由 AI Agent 完成**，你只用动嘴：

1. 把仓库交给你的 Agent（如 Kimi Code），对它说：

   > 读一下这个仓库的 AGENTS.md，然后帮我部署 Agent Remote。

2. Agent 会按仓库内置的操作手册（`AGENTS.md` + `.kimi-code/skills/`）一步步做：云服务器安装 → Windows 安装 → 手机 App 构建，风险操作前会向你说明。

3. 日常使用也是动嘴：
   - 「帮我巡检一下」→ Agent 按 `agent-remote-inspect` 流程检查全链路
   - 「批准审批码 XXXXXXXX」→ Agent 按 `agent-remote-enroll` 的安全流程审批
   - 「接入酒馆 / 接入一个新应用」→ Agent 按 `agent-remote-add-app` 引导完成
   - 「把改动上线」→ Agent 按 `agent-remote-deploy` 的固定顺序部署并验证

你需要准备的就三样：一台有公网地址的服务器（或让手机和电脑处于同一局域网）、一台 Windows 电脑、一部 Android 手机。

## 写给 Agent 的（人类不用读）

- `AGENTS.md`：工作规则、安全红线、事故教训、构建验证命令
- `.kimi-code/skills/`：巡检、审批、接应用、上线的标准流程
- `docs/`：安全模型、故障排查、升级、卸载的执行参考
- `PLAN.md` 与 `AGENTS.local.md` 是本地文件（不入库）：前者是路线图，后者是部署实例信息

## License

[Apache-2.0](LICENSE)

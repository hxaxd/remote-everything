---
name: agent-remote-add-app
description: Agent Remote 接入新应用：校验前置条件并调用 windows/register-app.ps1 完成注册
whenToUse: 当用户要求添加、注册、接入一个新的被控应用时
---

把一个新应用接入 Agent Remote。步骤：

1. 前置校验：应用必须有监听 `127.0.0.1` 独立端口的 Web 服务；确认启动命令、停止命令、探活端口、网页令牌。缺任何一项先和用户确认，不要猜。
2. 准备参数：id（`^[a-z0-9][a-z0-9._-]{0,63}$`）、名称、说明、图标字符、主题色、WebUrl（`https://<公网地址>/__agent_remote/open/<id>#token=<应用令牌>`）、ProxyUrl、Command/Arguments、StopCommand/StopArguments、Probe、WorkDir（应用需要工作目录时填写，如 SillyTavern）。
3. 调用 `windows/register-app.ps1` 注册（参数形态见 `README.md` 第 7 节）。
4. 用应用目录接口验证新应用出现且状态可流转（stopped → start → ready）。
5. 提醒用户在手机端「进入」验证页面能打开；失败时按 `AGENTS.local.md` 的故障定位顺序排查，先查 `127.0.0.1:58627` 与 `%LOCALAPPDATA%\AgentRemote\logs`。

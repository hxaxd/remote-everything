---
name: remote-everything-inspect
description: Remote Everything 日常只读巡检：检查云端服务、Windows 计划任务与端口、应用目录状态
whenToUse: 当用户要求检查系统状态、排障前的现状确认、或日常巡检时
arguments:
  - scope
---

执行 Remote Everything 只读巡检，不得做任何修改。实例信息（SSH 别名、服务器地址）从仓库根目录 `AGENTS.local.md` 读取；该文件不存在时向用户索要。

范围：$scope（缺省 = 全部）

1. Windows：`RemoteEverything-*` 计划任务状态；`127.0.0.1:58626/58627/58632` 是否在监听；`%LOCALAPPDATA%\RemoteEverything\logs` 最新日志。
2. 云端：`caddy`、`remote-everything-gateway-status`、`remote-everything-enrollment` 均为 active；近 10 分钟日志尾部。
3. 应用目录：在远端 shell 内读取 token 调 `/__remote_everything/apps`（token 只在远端使用，不带回本机、不打印）。

判定标准与异常排查顺序见 `AGENTS.local.md` 的「日常只读巡检」与「故障定位顺序」。输出：每项 正常/异常，异常项给出最可能原因。

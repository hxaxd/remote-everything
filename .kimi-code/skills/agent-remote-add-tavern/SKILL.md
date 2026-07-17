---
name: agent-remote-add-tavern
description: 接入酒馆 SillyTavern（AI 角色扮演）为 Agent Remote 被控应用的完整预案与注意事项
whenToUse: 当用户要求把酒馆、SillyTavern、AI 角色扮演应用接入 Agent Remote 时
---

酒馆 = SillyTavern（AI 角色扮演应用），本机位于 `~/learn/SillyTavern`（官方 git remote，工作树应保持干净）。接入前按本预案执行，不要跳过注意事项。

## 已验证事实（2026-07-17）

- 启动：`node server.js`（`NODE_ENV=production`），**必须有工作目录**——用 `register-app.ps1 -WorkDir` 指向安装目录（windows-control 已支持 `workdir` 字段）。
- Node 无系统 PATH：用 fnm 绝对路径 `C:\Users\<用户>\AppData\Roaming\fnm\node-versions\<版本>\installation\node.exe`（先 `ls` 确认最新版本）；bun（`~/.bun/bin/bun`）为备选。
- 更新：先确认 `git status` 干净，再 `git pull --rebase --autostash`；有本地改动就停下来报告，不擅自处理。
- 冒烟：后台启动约 10 秒后 `curl http://127.0.0.1:18000/` 应返回 200。
- 停止：酒馆无 CLI 停止命令，依赖 supervisor 按 enabled 标记 Kill 进程；`StopCommand` 留空走默认即可。

## 注意事项（用户已定调，勿擅自动）

- **鉴权方案未决**：酒馆是独立复杂应用、自带多租户能力，与 Agent Remote 单用户模型的关系需要专门设计。不要擅自开 basicAuth、不要擅自改它的多租户配置，接入前先和用户讨论。
- `config.yaml` 当前 `listen: true`（监听 0.0.0.0:18000，无应用层鉴权）。收口为 `listen: false` 前必须确认用户没有从其他设备局域网直连。
- 端口 18000 是它自己的配置，注册时 Probe/ProxyUrl 以 `config.yaml` 实际 `port` 为准。

## 注册命令模板（鉴权方案定了再用）

```powershell
.\windows\register-app.ps1 `
  -Id 'tavern' -Name '酒馆' -Description 'SillyTavern AI 角色扮演' `
  -Icon 'T' -Accent '#a855f7' `
  -WebUrl "https://$env:PUBLIC_HOST/__agent_remote/open/tavern" `
  -ProxyUrl 'http://127.0.0.1:18000' `
  -Command 'C:\Users\<用户>\AppData\Roaming\fnm\node-versions\<版本>\installation\node.exe' `
  -Arguments @('server.js') `
  -WorkDir "C:\Users\<用户>\learn\SillyTavern" `
  -Probe '127.0.0.1:18000' `
  -Enabled $true
```

注册后按 `agent-remote-add-app` skill 的第 4、5 步验证（目录状态流转 + 手机端进入）。

---
name: agent-remote-enroll
description: Agent Remote 设备审批与吊销：核对注册请求、安全执行 approve/revoke
whenToUse: 当用户提供 8 位审批码要求批准设备、要求吊销设备、或查看注册请求列表时
arguments:
  - action
  - value
---

在服务器上执行设备 $action（目标：$value）。严格遵守安全流程：

1. 先 `agent-remote-enroll list`，核对目标请求的设备名、交付方式（pkcs12）、创建时间、请求 ID；任何一项对不上就停下来问用户，不盲批。
2. approve 的输出含完整 p12 凭据，绝不打印到对话。固定用法：
   ```bash
   umask 077
   agent-remote-enroll approve '<精确审批码>' >/root/.agent-remote-approve.tmp
   agent-remote-enroll list
   rm -f /root/.agent-remote-approve.tmp
   ```
3. revoke 按证书指纹执行，执行前与用户确认该指纹对应的设备。
4. 完成后用脱敏的 `list` 输出核验最终状态。

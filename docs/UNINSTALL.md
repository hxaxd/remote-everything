# 卸载指南

按组件逆序卸载。所有操作可追踪：每项都列出会被删除的东西。

## 1. 吊销设备（可选但推荐）

```bash
ssh <服务器> "agent-remote-enroll list"
ssh <服务器> "agent-remote-enroll revoke <设备证书指纹>"
```

## 2. Android

直接卸载应用即可。注意：卸载会删除本机凭据（加密的 p12 与密钥），重装后需重新走注册审批流程。

## 3. Windows

```powershell
# 停止并删除计划任务
Stop-ScheduledTask -TaskName 'AgentRemote-*' -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName 'AgentRemote-Apps','AgentRemote-LocalControl','AgentRemote-Tunnel' -Confirm:$false

# 停止被控应用（默认 Kimi Web）
& "$env:LOCALAPPDATA\AgentRemote\agent-remote-control.exe" stop kimi 2>$null

# 删除状态目录（含控制程序、日志、注册表、隧道密钥、sshd 配置）
Remove-Item -Recurse -Force "$env:LOCALAPPDATA\AgentRemote"
```

被删除的内容：三个计划任务、`%LOCALAPPDATA%\AgentRemote\` 整个目录。安装时若启用了 OpenSSH Server 系统功能，可保留（系统组件，无害）；要移除用 `Remove-WindowsCapability -Online -Name 'OpenSSH.Server~~~~0.0.1.0'`。

Android 签名材料在独立的 `%LOCALAPPDATA%\AgentRemoteSign\`，不随运行时目录删除；彻底退出时才手动删除（删除后无法再发布同签名更新）。

## 4. 云服务器

```bash
systemctl disable --now kimi-gateway-status kimi-enrollment
rm -f /etc/systemd/system/kimi-gateway-*.service
rm -rf /opt/kimi-gateway /etc/kimi-gateway /var/lib/kimi-enrollment /var/lib/kimi-control /var/lib/kimi-tunnel
rm -f /etc/ssh/sshd_config.d/90-kimi-tunnel.conf && systemctl reload ssh
userdel kimi-tunnel 2>/dev/null; userdel kimi-control 2>/dev/null; userdel kimi-enroll 2>/dev/null
rm -f /usr/local/sbin/agent-remote-enroll /usr/local/sbin/agent-remote-gateway /usr/local/sbin/agent-remote-register-windows-host /usr/local/sbin/kimi-enroll
rm -rf /root/agent-remote-bundle /root/agent-remote-server
```

Caddy 本身按需处理：还原 `/etc/caddy/Caddyfile` 或 `systemctl disable --now caddy`。Caddy 是通过 apt 安装的，要彻底移除用 `apt-get remove --purge caddy`。

## 5. 域名/防火墙

关闭安全组或防火墙里为部署放行的端口（443；若曾开 80 一并关闭）。

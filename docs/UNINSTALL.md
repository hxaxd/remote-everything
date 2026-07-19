# 卸载指南

按组件逆序卸载。所有操作可追踪：每项都列出会被删除的东西。

## 1. 吊销设备（可选但推荐）

```bash
ssh <服务器> "remote-everything-enroll list"
ssh <服务器> "remote-everything-enroll revoke <设备证书指纹>"
```

## 2. Android

直接卸载应用即可。注意：卸载会删除本机凭据（加密的 p12 与密钥），重装后需重新走注册审批流程。

## 3. Windows

```powershell
# 停止并删除计划任务
Stop-ScheduledTask -TaskName 'RemoteEverything-*' -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName 'RemoteEverything-Apps','RemoteEverything-Tunnel' -Confirm:$false

# 停止被控应用（默认 Kimi Web）
& "$env:LOCALAPPDATA\RemoteEverything\remote-everything-control.exe" stop kimi 2>$null

# 删除状态目录（含控制程序、frpc、日志、应用注册表、令牌与 frpc 配置）
Remove-Item -Recurse -Force "$env:LOCALAPPDATA\RemoteEverything"
```

被删除的内容：计划任务（`RemoteEverything-Apps`、`RemoteEverything-Tunnel`）以及 `%LOCALAPPDATA%\RemoteEverything\` 整个目录。

Android 签名材料在独立的 `%LOCALAPPDATA%\RemoteEverythingSign\`，不随运行时目录删除；彻底退出时才手动删除（删除后无法再发布同签名更新）。

## 4. 云服务器

```bash
systemctl disable --now remote-everything-gateway-status remote-everything-enrollment frps
rm -f /etc/systemd/system/remote-everything-gateway-*.service /etc/systemd/system/frps.service
rm -rf /etc/remote-everything-gateway /var/lib/remote-everything-enrollment /var/lib/remote-everything-control /var/lib/remote-everything-frp
userdel remote-everything-control 2>/dev/null; userdel remote-everything-enroll 2>/dev/null; userdel remote-everything-frp 2>/dev/null
rm -f /usr/local/sbin/remote-everything-enroll /usr/local/sbin/remote-everything-gateway /usr/local/sbin/frps
rm -rf /root/remote-everything-bundle /root/remote-everything-server
```

Caddy 本身按需处理：还原 `/etc/caddy/Caddyfile` 或 `systemctl disable --now caddy`。Caddy 是通过 apt 安装的，要彻底移除用 `apt-get remove --purge caddy`。

## 5. 域名/防火墙

关闭安全组或防火墙里为部署放行的端口（443、7000；若曾开 80 一并关闭）。

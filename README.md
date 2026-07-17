# Agent 远程复现

## 1. 准备

- Ubuntu 24.04 云服务器，放行 TCP 22、443。
- Windows 10/11，安装 Kimi Code、Go、Android SDK、JDK 17+。
- iOS 构建机安装 macOS、Xcode、XcodeGen，并登录 Apple 开发者账号。

## 2. 云服务器

在项目根目录的 PowerShell 中执行：

```powershell
$env:PUBLIC_HOST = '服务器公网 IP 或域名'
$env:WINDOWS_USER = $env:USERNAME
scp -r .\server "root@$env:PUBLIC_HOST`:/root/agent-remote-server"
ssh "root@$env:PUBLIC_HOST" "chmod +x /root/agent-remote-server/*.sh /root/agent-remote-server/kimi-enroll; PUBLIC_HOST='$env:PUBLIC_HOST' WINDOWS_USER='$env:WINDOWS_USER' /root/agent-remote-server/install_gateway.sh"
scp -r "root@$env:PUBLIC_HOST`:/root/agent-remote-bundle" .\bundle
```

## 3. Windows 本机

```powershell
pwsh -ExecutionPolicy Bypass .\windows\install.ps1 -BundleDir .\bundle -ReplaceLegacyTasks
scp .\bundle\windows-host-key.pub "root@$env:PUBLIC_HOST`:/tmp/agent-remote-windows-host.pub"
ssh "root@$env:PUBLIC_HOST" "agent-remote-register-windows-host /tmp/agent-remote-windows-host.pub"
```

检查：

```powershell
Get-ScheduledTask -TaskName 'AgentRemote-*' | Select-Object TaskName, State
Get-NetTCPConnection -State Listen -LocalPort 58626,58627,58632
ssh "root@$env:PUBLIC_HOST" 'token=$(cat /etc/kimi-gateway/control-token); curl -fsS -H "Authorization: Bearer $token" http://127.0.0.1:58629/__agent_remote/apps'
```

## 4. Android

```powershell
pwsh .\configure-clients.ps1 -BundleDir .\bundle
Set-Location .\android
.\build-release.ps1
```

产物：

```text
android/app/build/outputs/apk/release/app-release.apk
```

## 5. iOS

在 macOS 项目根目录执行：

```bash
brew install xcodegen
chmod +x ios/build.sh
./ios/build.sh APPLE_TEAM_ID
```

产物：

```text
ios/build/export/AgentRemote.ipa
```

## 6. 设备审批

安装并打开手机客户端，取得 8 位审批码，然后执行：

```powershell
ssh "root@$env:PUBLIC_HOST" "agent-remote-enroll approve 8位审批码"
ssh "root@$env:PUBLIC_HOST" "agent-remote-enroll list"
```

吊销设备：

```powershell
ssh "root@$env:PUBLIC_HOST" "agent-remote-enroll revoke 设备证书SHA256指纹"
```

## 7. 动态注册应用

应用的本地 Web 服务必须监听 `127.0.0.1` 的独立端口。执行：

```powershell
$appId = '应用 ID'
$appPort = 59001
$appToken = '应用自己的网页令牌'
$appExe = 'C:\path\to\agent.exe'
.\windows\register-app.ps1 `
  -Id $appId `
  -Name '应用名称' `
  -Description '应用说明' `
  -Icon 'A' `
  -Accent '#2563eb' `
  -WebUrl "https://$env:PUBLIC_HOST/__agent_remote/open/$appId#token=$appToken" `
  -ProxyUrl "http://127.0.0.1:$appPort" `
  -Command $appExe `
  -Arguments @('server','run','--foreground','--host','127.0.0.1','--port',"$appPort") `
  -StopCommand $appExe `
  -StopArguments @('server','kill') `
  -Probe "127.0.0.1:$appPort" `
  -Enabled $true
```

注销：

```powershell
.\windows\unregister-app.ps1 -Id $appId
```

## 8. 全链路测试

```powershell
scp .\server\test_enrollment_pkcs12.py "root@$env:PUBLIC_HOST`:/tmp/agent-remote-full-test.py"
ssh "root@$env:PUBLIC_HOST" "PUBLIC_HOST='$env:PUBLIC_HOST' python3 /tmp/agent-remote-full-test.py"
```

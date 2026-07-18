param(
    [Parameter(Mandatory = $true)]
    [string]$BundleDir,
    [string]$KimiExe = '',
    [string]$FrpVersion = '0.70.0'
)

$ErrorActionPreference = 'Stop'
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()

$projectRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$bundle = (Resolve-Path -LiteralPath $BundleDir).Path
$config = Get-Content -LiteralPath (Join-Path $bundle 'config.json') -Raw | ConvertFrom-Json
if ($config.public_host -notmatch '^[A-Za-z0-9.-]+$') { throw 'Invalid public host.' }
if ($config.windows_user -ne $env:USERNAME) { throw "Bundle expects Windows user $($config.windows_user), current user is $env:USERNAME." }
if ($config.control_token -notmatch '^[a-f0-9]{64}$') { throw 'Invalid control token.' }
if ($config.frp_token -notmatch '^[a-f0-9]{64}$') { throw 'Invalid frp token. Fetch a fresh bundle from the server.' }

if (-not $KimiExe) {
    $candidate = Join-Path $env:USERPROFILE '.kimi-code\bin\kimi.exe'
    if (Test-Path -LiteralPath $candidate) {
        $KimiExe = $candidate
    }
    else {
        $command = Get-Command kimi.exe -ErrorAction SilentlyContinue
        if ($command) { $KimiExe = $command.Source }
    }
}
if (-not $KimiExe -or -not (Test-Path -LiteralPath $KimiExe)) { throw 'Kimi Code CLI was not found.' }

$go = Get-Command go.exe -ErrorAction SilentlyContinue
if (-not $go) { throw 'Go compiler was not found.' }

$stateRoot = Join-Path $env:LOCALAPPDATA 'AgentRemote'
$logs = Join-Path $stateRoot 'logs'
$controlTokenFile = Join-Path $stateRoot 'control-token'
New-Item -ItemType Directory -Path $stateRoot, $logs -Force | Out-Null
[IO.File]::WriteAllText($controlTokenFile, [string]$config.control_token, [Text.UTF8Encoding]::new($false))

$controlExecutable = Join-Path $stateRoot 'agent-remote-control.exe'
if (Get-ScheduledTask -TaskName 'AgentRemote-Apps' -ErrorAction SilentlyContinue) {
    Stop-ScheduledTask -TaskName 'AgentRemote-Apps' -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500
}
& $KimiExe server kill 2>$null
Start-Sleep -Milliseconds 500
Push-Location (Join-Path $projectRoot 'windows-control')
try {
    & $go.Source build -trimpath -ldflags '-s -w -H=windowsgui' -o $controlExecutable .
    if ($LASTEXITCODE -ne 0) { throw 'Windows control executable build failed.' }
}
finally {
    Pop-Location
}

# frpc 隧道客户端（钉版本；优先 gh，失败回退直接下载）
$frpcExecutable = Join-Path $stateRoot 'frpc.exe'
$frpcCurrent = $false
if (Test-Path -LiteralPath $frpcExecutable) {
    $frpcCurrent = ((& $frpcExecutable --version 2>$null) | Out-String) -match [regex]::Escape($FrpVersion)
}
if (-not $frpcCurrent) {
    $downloadDir = Join-Path $env:TEMP "agent-remote-frp-$FrpVersion"
    $zipName = "frp_${FrpVersion}_windows_amd64.zip"
    New-Item -ItemType Directory -Force $downloadDir | Out-Null
    $downloaded = $false
    if (Get-Command gh -ErrorAction SilentlyContinue) {
        & gh release download -R fatedier/frp -p $zipName -D $downloadDir --clobber 2>$null
        $downloaded = $LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath (Join-Path $downloadDir $zipName))
    }
    if (-not $downloaded) {
        Invoke-WebRequest -Uri "https://github.com/fatedier/frp/releases/download/v$FrpVersion/$zipName" -OutFile (Join-Path $downloadDir $zipName)
    }
    Expand-Archive -LiteralPath (Join-Path $downloadDir $zipName) -DestinationPath $downloadDir -Force
    Copy-Item -LiteralPath (Join-Path $downloadDir "frp_${FrpVersion}_windows_amd64\frpc.exe") -Destination $frpcExecutable -Force
    Remove-Item -Recurse -Force $downloadDir
}

# ttyd 终端（钉版本；应用默认不启用）
$ttydVersion = '1.7.7'
$ttydExecutable = Join-Path $stateRoot 'ttyd.exe'
$ttydCurrent = $false
if (Test-Path -LiteralPath $ttydExecutable) {
    $ttydCurrent = ((& $ttydExecutable --version 2>$null) | Out-String) -match [regex]::Escape($ttydVersion)
}
if (-not $ttydCurrent) {
    $downloadDir = Join-Path $env:TEMP "agent-remote-ttyd-$ttydVersion"
    New-Item -ItemType Directory -Force $downloadDir | Out-Null
    $downloaded = $false
    if (Get-Command gh -ErrorAction SilentlyContinue) {
        & gh release download -R tsl0922/ttyd -p 'ttyd.win32.exe' -D $downloadDir --clobber 2>$null
        $downloaded = ($LASTEXITCODE -eq 0) -and (Test-Path -LiteralPath (Join-Path $downloadDir 'ttyd.win32.exe'))
    }
    if (-not $downloaded) {
        Invoke-WebRequest -Uri "https://github.com/tsl0922/ttyd/releases/download/$ttydVersion/ttyd.win32.exe" -OutFile (Join-Path $downloadDir 'ttyd.win32.exe')
    }
    Copy-Item -LiteralPath (Join-Path $downloadDir 'ttyd.win32.exe') -Destination $ttydExecutable -Force
    Remove-Item -Recurse -Force $downloadDir
}

$frpcConfig = Join-Path $stateRoot 'frpc.toml'
foreach ($credential in @('pc-wss.crt.pem', 'pc-wss.key.pem')) {
    $source = Join-Path $bundle $credential
    if (-not (Test-Path -LiteralPath $source)) { throw "Missing bundle file: $credential" }
    Copy-Item -LiteralPath $source -Destination (Join-Path $stateRoot $credential) -Force
}
$pcCert = (Join-Path $stateRoot 'pc-wss.crt.pem').Replace('\', '/')
$pcKey = (Join-Path $stateRoot 'pc-wss.key.pem').Replace('\', '/')
$frpcLogPath = (Join-Path $logs 'frpc.log').Replace('\', '/')
$frpcToml = @"
serverAddr = "$($config.public_host)"
serverPort = 443
transport.protocol = "wss"
transport.tls.enable = true
transport.tls.certFile = "$pcCert"
transport.tls.keyFile = "$pcKey"
auth.method = "token"
auth.token = "$($config.frp_token)"
loginFailExit = false
log.to = "$frpcLogPath"
log.level = "info"
log.maxDays = 7

[[proxies]]
name = "agent-remote"
type = "tcp"
localIP = "127.0.0.1"
localPort = 58627
remotePort = 58628
"@
[IO.File]::WriteAllText($frpcConfig, $frpcToml, [Text.UTF8Encoding]::new($false))

# SSH 隧道时代遗留全部清除
foreach ($legacyPath in @('sshd', 'run-control-hidden.vbs', 'run-tunnel-hidden.vbs', 'run-kimi-hidden.vbs', 'tunnel-client.key', 'server-known-hosts')) {
    $target = Join-Path $stateRoot $legacyPath
    if (Test-Path -LiteralPath $target) { Remove-Item -Recurse -Force $target }
}
foreach ($legacyProcess in @('wscript', 'ssh', 'sshd')) {
    Get-Process -Name $legacyProcess -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
}
foreach ($legacyLog in @('control-sshd.log', 'tunnel.log', 'registration-test.log')) {
    $target = Join-Path $logs $legacyLog
    if (Test-Path -LiteralPath $target) { Remove-Item -Force $target -ErrorAction SilentlyContinue }
}
if (Get-ScheduledTask -TaskName 'AgentRemote-LocalControl' -ErrorAction SilentlyContinue) {
    Stop-ScheduledTask -TaskName 'AgentRemote-LocalControl' -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName 'AgentRemote-LocalControl' -Confirm:$false
}

$sid = $identity.User.Value
foreach ($securedFile in @($controlTokenFile, $frpcConfig, (Join-Path $stateRoot 'pc-wss.key.pem'))) {
    & icacls.exe $securedFile /inheritance:r /grant:r "*$sid`:F" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "ACL update failed: $securedFile" }
}

$kimiTokenFile = Join-Path $env:USERPROFILE '.kimi-code\server.token'
if (-not (Test-Path -LiteralPath $kimiTokenFile)) { throw 'Kimi server token was not found.' }
$kimiToken = (Get-Content -LiteralPath $kimiTokenFile -Raw).Trim()
if ($kimiToken -notmatch '^[A-Za-z0-9_-]{20,200}$') { throw 'Invalid Kimi server token.' }
$kimiWebUrl = "https://$($config.public_host)/__agent_remote/open/kimi#token=$kimiToken"
$kimiArguments = @('server', 'run', '--foreground', '--port', '58632', '--host', '127.0.0.1', '--allowed-host', [string]$config.public_host, '--keep-alive', '--log-level', 'info')
& (Join-Path $projectRoot 'windows\register-app.ps1') `
    -Id 'kimi' `
    -Name 'Kimi Code' `
    -Description '远程连接和控制 Kimi Code' `
    -Icon 'K' `
    -Accent '#2563eb' `
    -WebUrl $kimiWebUrl `
    -ProxyUrl 'http://127.0.0.1:58632' `
    -Command $KimiExe `
    -Arguments $kimiArguments `
    -StopCommand $KimiExe `
    -StopArguments @('server', 'kill') `
    -Probe '127.0.0.1:58632' `
    -Enabled $true | Out-Null
& (Join-Path $projectRoot 'windows\register-app.ps1') `
    -Id 'files' `
    -Name '文件管理' `
    -Description '浏览、预览、上传和下载电脑文件' `
    -Icon 'F' `
    -Accent '#22c55e' `
    -WebUrl "https://$($config.public_host)/__agent_remote/open/files" `
    -ProxyUrl 'http://127.0.0.1:58633' `
    -Command $controlExecutable `
    -Arguments @('files') `
    -Probe '127.0.0.1:58633' `
    -Enabled $true | Out-Null
& (Join-Path $projectRoot 'windows\register-app.ps1') `
    -Id 'terminal' `
    -Name '终端' `
    -Description '远程 PowerShell（默认关闭，谨慎开启）' `
    -Icon '>_' `
    -Accent '#f59e0b' `
    -WebUrl "https://$($config.public_host)/__agent_remote/open/terminal" `
    -ProxyUrl 'http://127.0.0.1:58634' `
    -Command $ttydExecutable `
    -Arguments @('-i','127.0.0.1','-p','58634','-W','powershell.exe') `
    -Probe '127.0.0.1:58634' `
    -Enabled $false | Out-Null

$frpcVbs = Join-Path $stateRoot 'run-frpc-hidden.vbs'
$frpcVbsText = @"
Option Explicit
Dim shell, fso, exe, configPath, command, exitCode
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
exe = fso.GetParentFolderName(WScript.ScriptFullName) & "\frpc.exe"
configPath = fso.GetParentFolderName(WScript.ScriptFullName) & "\frpc.toml"
command = Quote(exe) & " -c " & Quote(configPath)
Do
  exitCode = shell.Run(command, 0, True)
  WScript.Sleep 5000
Loop
Function Quote(value)
  Quote = Chr(34) & value & Chr(34)
End Function
"@
[IO.File]::WriteAllText($frpcVbs, $frpcVbsText, [Text.UTF8Encoding]::new($false))

$taskUser = $identity.Name
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $taskUser
$interactivePrincipal = New-ScheduledTaskPrincipal -UserId $taskUser -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero)
$taskActions = [ordered]@{
    'AgentRemote-Apps' = New-ScheduledTaskAction -Execute $controlExecutable -Argument 'serve'
    'AgentRemote-Tunnel' = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\wscript.exe" -Argument ('"' + $frpcVbs + '"')
}
foreach ($entry in $taskActions.GetEnumerator()) {
    Register-ScheduledTask -TaskName $entry.Key -Action $entry.Value -Trigger $trigger -Principal $interactivePrincipal -Settings $settings -Description 'Agent Remote background service' -Force | Out-Null
}
foreach ($task in $taskActions.Keys) { Start-ScheduledTask -TaskName $task }

& (Join-Path $projectRoot 'configure-clients.ps1') -BundleDir $bundle | Out-Null

$routerReady = $false
$kimiReady = $false
for ($attempt = 0; $attempt -lt 30; $attempt++) {
    Start-Sleep -Milliseconds 500
    $routerReady = [bool](Get-NetTCPConnection -State Listen -LocalAddress 127.0.0.1 -LocalPort 58627 -ErrorAction SilentlyContinue)
    $kimiReady = [bool](Get-NetTCPConnection -State Listen -LocalAddress 127.0.0.1 -LocalPort 58632 -ErrorAction SilentlyContinue)
    if ($routerReady -and $kimiReady) { break }
}
if (-not $routerReady) { throw 'Application router did not start.' }
if (-not $kimiReady) { throw 'Kimi Web service did not start.' }

[pscustomobject]@{
    ok = $true
    state_root = $stateRoot
    router_listener = $routerReady
    kimi_listener = $kimiReady
    tunnel = "frpc $FrpVersion"
    apps = @('kimi')
} | ConvertTo-Json

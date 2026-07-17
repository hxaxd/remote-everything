param(
    [Parameter(Mandatory = $true)]
    [string]$BundleDir,
    [string]$KimiExe = ''
)

$ErrorActionPreference = 'Stop'
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
$isAdministrator = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

$projectRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$bundle = (Resolve-Path -LiteralPath $BundleDir).Path
$config = Get-Content -LiteralPath (Join-Path $bundle 'config.json') -Raw | ConvertFrom-Json
if ($config.public_host -notmatch '^[A-Za-z0-9.-]+$') { throw 'Invalid public host.' }
if ($config.windows_user -ne $env:USERNAME) { throw "Bundle expects Windows user $($config.windows_user), current user is $env:USERNAME." }
if ($config.control_token -notmatch '^[a-f0-9]{64}$') { throw 'Invalid control token.' }

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
$sshdExecutable = Join-Path $env:SystemRoot 'System32\OpenSSH\sshd.exe'
if (-not (Test-Path -LiteralPath $sshdExecutable)) {
    if (-not $isAdministrator) { throw 'OpenSSH Server is missing. Run this script once in an elevated PowerShell session.' }
    Add-WindowsCapability -Online -Name 'OpenSSH.Server~~~~0.0.1.0' | Out-Null
}

$stateRoot = Join-Path $env:LOCALAPPDATA 'AgentRemote'
$logs = Join-Path $stateRoot 'logs'
$sshdRoot = Join-Path $stateRoot 'sshd'
$controlTokenFile = Join-Path $stateRoot 'control-token'
New-Item -ItemType Directory -Path $stateRoot, $logs, $sshdRoot -Force | Out-Null
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

$tunnelKey = Join-Path $stateRoot 'tunnel-client.key'
$serverKnownHosts = Join-Path $stateRoot 'server-known-hosts'
Copy-Item -LiteralPath (Join-Path $bundle 'tunnel-client.key') -Destination $tunnelKey -Force
$serverHostParts = (Get-Content -LiteralPath (Join-Path $bundle 'server-host.pub') -Raw).Trim() -split '\s+'
if ($serverHostParts.Count -lt 2 -or $serverHostParts[0] -ne 'ssh-ed25519') { throw 'Invalid server host key.' }
[IO.File]::WriteAllText($serverKnownHosts, "$($config.public_host) $($serverHostParts[0]) $($serverHostParts[1])`n", [Text.UTF8Encoding]::new($false))

$hostKey = Join-Path $sshdRoot 'ssh_host_ed25519_key'
if (-not (Test-Path -LiteralPath $hostKey)) {
    & "$env:SystemRoot\System32\OpenSSH\ssh-keygen.exe" -q -t ed25519 -N '' -f $hostKey
    if ($LASTEXITCODE -ne 0) { throw 'Local SSH host key creation failed.' }
}
$controlPublicKey = (Get-Content -LiteralPath (Join-Path $bundle 'cloud-control.pub') -Raw).Trim()
if ($controlPublicKey -notmatch '^ssh-ed25519\s+[A-Za-z0-9+/=]+') { throw 'Invalid cloud control public key.' }
$authorizedKeys = Join-Path $sshdRoot 'authorized_keys'
$forced = 'command="' + $controlExecutable + '",no-port-forwarding,no-agent-forwarding,no-X11-forwarding,no-pty ' + $controlPublicKey
[IO.File]::WriteAllText($authorizedKeys, "$forced`n", [Text.UTF8Encoding]::new($false))

$toSshPath = { param([string]$Path) $Path.Replace('\', '/') }
$sshdConfig = Join-Path $sshdRoot 'sshd_config'
$sshdText = @"
Port 58626
ListenAddress 127.0.0.1
HostKey $(& $toSshPath $hostKey)
AuthorizedKeysFile $(& $toSshPath $authorizedKeys)
PidFile $(& $toSshPath (Join-Path $sshdRoot 'sshd.pid'))
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no
AllowUsers $env:USERNAME
AllowAgentForwarding no
AllowTcpForwarding no
AllowStreamLocalForwarding no
PermitTunnel no
X11Forwarding no
PermitTTY no
StrictModes no
LogLevel VERBOSE
"@
[IO.File]::WriteAllText($sshdConfig, $sshdText, [Text.UTF8Encoding]::new($false))
& $sshdExecutable -t -f $sshdConfig
if ($LASTEXITCODE -ne 0) { throw 'Local SSH configuration validation failed.' }

$sid = $identity.User.Value
foreach ($securedFile in @($tunnelKey, $authorizedKeys, $hostKey, $controlTokenFile)) {
    & icacls.exe $securedFile /inheritance:r /grant:r "*$sid`:F" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "ACL update failed: $securedFile" }
}

$sshdVbs = Join-Path $stateRoot 'run-control-hidden.vbs'
$tunnelVbs = Join-Path $stateRoot 'run-tunnel-hidden.vbs'

$sshdScript = @"
Option Explicit
Dim shell, command, exitCode
Set shell = CreateObject("WScript.Shell")
command = Quote("$sshdExecutable") & " -D -e -f " & Quote("$sshdConfig") & " -E " & Quote("$(Join-Path $logs 'control-sshd.log')")
Do
  exitCode = shell.Run(command, 0, True)
  WScript.Sleep 5000
Loop
Function Quote(value)
  Quote = Chr(34) & value & Chr(34)
End Function
"@
$tunnelScript = @"
Option Explicit
Dim shell, command, exitCode
Set shell = CreateObject("WScript.Shell")
command = Quote("$env:SystemRoot\System32\OpenSSH\ssh.exe") & " -NT -i " & Quote("$tunnelKey") & " -o IdentitiesOnly=yes -o BatchMode=yes -o ExitOnForwardFailure=yes -o ServerAliveInterval=20 -o ServerAliveCountMax=3 -o ConnectTimeout=15 -o ConnectionAttempts=3 -o StrictHostKeyChecking=yes -o UserKnownHostsFile=" & Quote("$serverKnownHosts") & " -o LogLevel=ERROR -E " & Quote("$(Join-Path $logs 'tunnel.log')") & " -R 127.0.0.1:58628:127.0.0.1:58627 -R 127.0.0.1:58630:127.0.0.1:58626 kimi-tunnel@$($config.public_host)"
Do
  exitCode = shell.Run(command, 0, True)
  WScript.Sleep 5000
Loop
Function Quote(value)
  Quote = Chr(34) & value & Chr(34)
End Function
"@
[IO.File]::WriteAllText($sshdVbs, $sshdScript, [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText($tunnelVbs, $tunnelScript, [Text.UTF8Encoding]::new($false))

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

$taskUser = $identity.Name
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $taskUser
$taskPrincipal = New-ScheduledTaskPrincipal -UserId $taskUser -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero)
$taskActions = [ordered]@{
    'AgentRemote-Apps' = New-ScheduledTaskAction -Execute $controlExecutable -Argument 'serve'
    'AgentRemote-LocalControl' = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\wscript.exe" -Argument ('"' + $sshdVbs + '"')
    'AgentRemote-Tunnel' = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\wscript.exe" -Argument ('"' + $tunnelVbs + '"')
}
foreach ($entry in $taskActions.GetEnumerator()) {
    Register-ScheduledTask -TaskName $entry.Key -Action $entry.Value -Trigger $trigger -Principal $taskPrincipal -Settings $settings -Description 'Agent Remote background service' -Force | Out-Null
}

foreach ($task in $taskActions.Keys) { Start-ScheduledTask -TaskName $task }

$hostKeyOutput = Join-Path $bundle 'windows-host-key.pub'
Copy-Item -LiteralPath "${hostKey}.pub" -Destination $hostKeyOutput -Force
& (Join-Path $projectRoot 'configure-clients.ps1') -BundleDir $bundle | Out-Null

$controlReady = $false
$routerReady = $false
$kimiReady = $false
for ($attempt = 0; $attempt -lt 30; $attempt++) {
    Start-Sleep -Milliseconds 500
    $controlReady = [bool](Get-NetTCPConnection -State Listen -LocalAddress 127.0.0.1 -LocalPort 58626 -ErrorAction SilentlyContinue)
    $routerReady = [bool](Get-NetTCPConnection -State Listen -LocalAddress 127.0.0.1 -LocalPort 58627 -ErrorAction SilentlyContinue)
    $kimiReady = [bool](Get-NetTCPConnection -State Listen -LocalAddress 127.0.0.1 -LocalPort 58632 -ErrorAction SilentlyContinue)
    if ($controlReady -and $routerReady -and $kimiReady) { break }
}
if (-not $controlReady) { throw 'Local control service did not start.' }
if (-not $routerReady) { throw 'Application router did not start.' }
if (-not $kimiReady) { throw 'Kimi Web service did not start.' }

[pscustomobject]@{
    ok = $true
    state_root = $stateRoot
    control_listener = $controlReady
    router_listener = $routerReady
    kimi_listener = $kimiReady
    apps = @('kimi')
    windows_host_key = $hostKeyOutput
} | ConvertTo-Json

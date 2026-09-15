# ============================================================
# Remote Everything 节点离线恢复脚本
# 问题: 节点 frpc <-> 云端 frps 的 FRP 隧道断开
# 证据: frpc 持续 "i/o deadline reached"; 云端 frps 进程活着但登录握手无响应
#       (隧道证书/配置未变未过期)
#
# 实测修正:
#   * Stop-ScheduledTask 只杀 VBS launcher 的 wscript, Shell.Run 拉起的
#     frpc.exe 会变成孤立进程继续跑; 必须显式 Stop-Process 清掉所有残留
#     frpc.exe, 否则再 Start 会出现双 frpc 抢同一代理,
#     云端 frps 日志持续报 "proxy already exists"。
#   * 云端 frps 日志在 /var/lib/remote-everything/.runtime/logs/frps.log
#     (frps.service 用 StandardOutput=append; 不是 frps-service.log)。
#   * 云端连接使用 ~/.ssh/config 中配置的 SSH 别名（公钥认证）。
#     installationId、别名、探活地址等部署事实只记录在 AGENTS.local.md，
#     不固化在脚本里。
# 顺序必须固定: 停 frpc -> 清残留 -> 重启云端 frps -> 起 frpc
# (frpc 抢先重连会挤掉 frps; 双实例会导致 proxy already exists)
#
# 用法示例（参数值取自 AGENTS.local.md 与服务端 server.json）:
#   ./scripts/recover-frp-tunnel.ps1 `
#       -InstallationId <64位hex installationId> `
#       -ServerAlias <~/.ssh/config 中的云端别名> `
#       -TunnelProbe http://127.0.0.1:<node_tunnel_listen 端口>/__remote_everything/apps
# ============================================================

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9a-f]{64}$')]
    [string]$InstallationId,

    # ~/.ssh/config 中配置的云端 SSH 别名（公钥认证）
    [Parameter(Mandatory = $true)]
    [string]$ServerAlias,

    # 云端 loopback 探活地址，取自服务端 server.json 的 node_tunnel_listen，
    # 形如 http://127.0.0.1:<port>/__remote_everything/apps
    [Parameter(Mandatory = $true)]
    [string]$TunnelProbe,

    [string]$FrpcTaskName = 'frpc',

    # 节点本地 frpc 日志，默认取仓库 .runtime/logs 下的标准位置
    [string]$FrpcLog = (Join-Path $PSScriptRoot '..\.runtime\logs\frpc.log'),

    [string]$FrpsLog = '/var/lib/remote-everything/.runtime/logs/frps.log'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$frpcTaskPath = "\RemoteEverything\$InstallationId\"
$frpsUnit     = "remote-everything-$InstallationId-frps"

# ---- 第 0 步: 前置检查 ----
Write-Host '== [0/5] Pre-flight checks =='
if (-not (Get-Command ssh -ErrorAction SilentlyContinue)) { throw 'ssh is not available on PATH.' }
ssh -o BatchMode=yes -o ConnectTimeout=10 $ServerAlias 'true' 2>$null
if ($LASTEXITCODE -ne 0) { throw "SSH alias '$ServerAlias' is not usable (configure it in ~/.ssh/config with public-key auth)." }
$task = Get-ScheduledTask -TaskPath $frpcTaskPath -TaskName $FrpcTaskName -ErrorAction SilentlyContinue
if (-not $task) { throw "Scheduled task '$frpcTaskPath$FrpcTaskName' was not found on this node." }

# ---- 第 1 步 (PowerShell): 停 frpc 计划任务 ----
Write-Host '== [1/5] Stopping frpc scheduled task =='
Stop-ScheduledTask -TaskPath $frpcTaskPath -TaskName $FrpcTaskName

# ---- 第 2 步 (PowerShell): 清掉所有残留 frpc.exe（关键修正）----
Write-Host '== [2/5] Killing any residual frpc.exe =='
Get-CimInstance Win32_Process -Filter "Name='frpc.exe'" | ForEach-Object {
    Write-Host "  killing residual frpc.exe PID $($_.ProcessId)"
    Stop-Process -Id $_.ProcessId -Force
}
Start-Sleep 2
$leftover = Get-CimInstance Win32_Process -Filter "Name='frpc.exe'"
if ($leftover) {
    throw "ERROR: frpc.exe still running: $($leftover.ProcessId -join ',')"
}
Write-Host '  OK: no frpc.exe running'

# ---- 第 3 步 (SSH 到云端): 确认服务名并重启 frps ----
Write-Host '== [3/5] Restarting cloud frps =='
ssh $ServerAlias "systemctl list-units 'remote-everything-$InstallationId*' --no-pager"
ssh $ServerAlias "systemctl restart $frpsUnit && sleep 2 && systemctl is-active $frpsUnit"
if ($LASTEXITCODE -ne 0) { throw "Cloud unit $frpsUnit did not restart successfully." }

# ---- 第 4 步 (PowerShell): 起回唯一 frpc ----
Write-Host '== [4/5] Starting frpc scheduled task =='
Start-ScheduledTask -TaskPath $frpcTaskPath -TaskName $FrpcTaskName

# ---- 第 5 步: 验证 ----
Write-Host '== [5/5] Verifying =='
Start-Sleep 15
$frpcCount = (Get-CimInstance Win32_Process -Filter "Name='frpc.exe'" | Measure-Object).Count
Write-Host "  frpc.exe count: $frpcCount   (必须恰好 1)"
if ($frpcCount -ne 1) { throw "Expected exactly 1 frpc.exe, found $frpcCount." }
if (Test-Path $frpcLog) { Get-Content $frpcLog -Tail 6 } else { Write-Warning "frpc log not found: $frpcLog" }    # 期望 "login to server success" + "start proxy success"
ssh $ServerAlias "tail -n 5 $FrpsLog"    # 期望 "new proxy ... success", 无 "already exists"
ssh $ServerAlias "curl -s -o /dev/null -w 'tunnel HTTP %{http_code}\n' --max-time 8 $TunnelProbe"   # 期望 200

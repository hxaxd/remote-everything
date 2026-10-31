# Recover one Windows node's tunnel, using its validated runtime component.
# Example: ./scripts/recover-frp-tunnel.ps1 -InstallationId HEX64
#   -RuntimePath C:/deployment/.runtime/runtime.json -ComponentId frpc
#   -ServerAlias server -TunnelProbe http://127.0.0.1:PORT/__remote_everything/apps
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9a-f]{64}$')]
    [string]$InstallationId,
    [Parameter(Mandatory = $true)]
    [string]$RuntimePath,
    [string]$Python = 'python',
    [string]$ComponentId = 'frpc',
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-zA-Z0-9_][a-zA-Z0-9_.-]*$')]
    [string]$ServerAlias,
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^http://127\.0\.0\.1:[0-9]{2,5}/__remote_everything/apps$')]
    [string]$TunnelProbe
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib/windows-process.ps1')

# Validate before stopping any task or process. All local identities and paths
# come from the selected component; the installation ID must agree with it.
if (-not $IsWindows) { throw 'This recovery script requires Windows.' }
& $Python (Join-Path $PSScriptRoot '../skills/remote-everything-install/scripts/runtime.py') validate $RuntimePath
if ($LASTEXITCODE -ne 0) { throw 'Invalid runtime record.' }
$runtime = Get-Content -LiteralPath $RuntimePath -Raw | ConvertFrom-Json
if ($runtime.installation_id -cne $InstallationId -or $runtime.platform -ne 'windows') {
    throw 'Runtime installation or platform does not match the recovery target.'
}
$components = @($runtime.components | Where-Object id -CEQ $ComponentId)
if ($components.Count -ne 1) { throw "Expected one runtime component '$ComponentId'." }
$component = $components[0]
if (-not $component.managed -or [IO.Path]::GetFileName($component.executable) -ine 'frpc.exe' -or
    $component.manager.type -ne 'scheduled-task') { throw 'Target must be a managed FRPC scheduled task.' }
$frpcTaskPath = "\RemoteEverything\$InstallationId\"
$taskId = [string]$component.manager.id
if (-not $taskId.StartsWith($frpcTaskPath, [StringComparison]::Ordinal) -or
    $taskId.Substring($frpcTaskPath.Length) -notmatch '^[a-zA-Z0-9_.-]+$') { throw 'Task identity does not belong to the target installation.' }
$taskName = $taskId.Substring($frpcTaskPath.Length)
$frpsUnit = "remote-everything-$InstallationId-frps"
if (-not (Get-Command ssh -ErrorAction SilentlyContinue)) { throw 'ssh is not available on PATH.' }
ssh -o BatchMode=yes -o ConnectTimeout=10 $ServerAlias 'true'
if ($LASTEXITCODE -ne 0) { throw "SSH alias '$ServerAlias' is not usable." }
$task = Get-ScheduledTask -TaskPath $frpcTaskPath -TaskName $taskName -ErrorAction SilentlyContinue
if (-not $task) { throw "Scheduled task '$taskId' was not found." }

Write-Host "Stopping $taskId and its matching FRPC processes"
Stop-ScheduledTask -TaskPath $frpcTaskPath -TaskName $taskName
foreach ($snapshot in @(Get-ComponentProcess $component)) {
    Stop-ComponentProcess $snapshot $component
}
if (@(Get-ComponentProcess $component).Count -ne 0) { throw 'Target FRPC processes are still running.' }

Write-Host "Restarting $frpsUnit"
ssh $ServerAlias "systemctl restart $frpsUnit && systemctl is-active $frpsUnit"
if ($LASTEXITCODE -ne 0) { throw "Cloud unit $frpsUnit did not restart successfully." }

Start-ScheduledTask -TaskPath $frpcTaskPath -TaskName $taskName
Start-Sleep -Seconds 15
$targetProcesses = @(Get-ComponentProcess $component)
if ($targetProcesses.Count -ne 1) { throw "Expected one target FRPC process, found $($targetProcesses.Count)." }
if (Test-Path -LiteralPath $component.log) { Get-Content -LiteralPath $component.log -Tail 6 }
ssh $ServerAlias "curl -s -o /dev/null -w '%{http_code}' --max-time 8 $TunnelProbe" | Tee-Object -Variable probeStatus
if ($LASTEXITCODE -ne 0 -or ($probeStatus -join '').Trim() -ne '200') { throw 'Tunnel HTTP probe failed.' }
Write-Host "Recovered $ComponentId ($InstallationId), PID $($targetProcesses[0].ProcessId)"

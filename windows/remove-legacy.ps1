$ErrorActionPreference = 'Stop'
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Administrator permission is required.' }

foreach ($required in @('AgentRemote-Apps', 'AgentRemote-LocalControl', 'AgentRemote-Tunnel')) {
    if (-not (Get-ScheduledTask -TaskName $required -ErrorAction SilentlyContinue)) { throw "Missing replacement task: $required" }
}
foreach ($port in @(58626, 58627, 58632)) {
    if (-not (Get-NetTCPConnection -State Listen -LocalAddress 127.0.0.1 -LocalPort $port -ErrorAction SilentlyContinue)) { throw "Replacement listener is missing: $port" }
}

foreach ($legacy in @('KimiRemote-KimiWeb', 'KimiRemote-LocalSSH', 'KimiRemote-Tunnel')) {
    if (Get-ScheduledTask -TaskName $legacy -ErrorAction SilentlyContinue) {
        Stop-ScheduledTask -TaskName $legacy -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $legacy -Confirm:$false
    }
}

$legacyRoot = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'KimiRemote'))
$localRoot = [IO.Path]::GetFullPath($env:LOCALAPPDATA)
if (-not $legacyRoot.StartsWith($localRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'Invalid legacy path.' }
$legacyProcesses = Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -and $_.CommandLine.IndexOf($legacyRoot, [StringComparison]::OrdinalIgnoreCase) -ge 0 }
foreach ($process in $legacyProcesses) {
    if ($process.ProcessId -ne $PID) {
        [Diagnostics.Process]::GetProcessById([int]$process.ProcessId).Kill()
    }
}
if (Test-Path -LiteralPath $legacyRoot) { Remove-Item -LiteralPath $legacyRoot -Recurse -Force }

$marker = Join-Path $env:LOCALAPPDATA 'AgentRemote\legacy-cleanup-complete'
New-Item -ItemType File -Path $marker -Force | Out-Null

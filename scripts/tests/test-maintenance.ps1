# Runs in a temporary directory. Scheduled tasks and SSH are stubbed; process
# matching and termination use real Windows processes.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$Root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
. (Join-Path $Root 'scripts/lib/windows-process.ps1')
function Assert($condition, [string]$message) { if (-not $condition) { throw $message } }
function Release-Function([string]$name) {
    $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $Root 'scripts/release-local.ps1'), [ref]$null, [ref]$null)
    $definition = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
    Assert ($null -ne $definition) "Missing release function $name"
    [scriptblock]::Create($definition.Extent.Text)
}

$scratch = Join-Path ([IO.Path]::GetTempPath()) ('remote-everything-maintenance-' + [guid]::NewGuid().ToString('N'))
$processes = [Collections.Generic.List[Diagnostics.Process]]::new()
New-Item -ItemType Directory -Path $scratch | Out-Null
try {
    . (Release-Function 'Project-GoToolchain')
    $previousTestGoToolchain = $env:GOTOOLCHAIN
    try {
        $env:GOTOOLCHAIN = Project-GoToolchain
        $actualToolchain = go env GOVERSION
        Assert ($LASTEXITCODE -eq 0 -and $actualToolchain -ceq $env:GOTOOLCHAIN) 'Release did not select its pinned patch toolchain'
    } finally { $env:GOTOOLCHAIN = $previousTestGoToolchain }
    # C1: resolve the real signing policy without touching signing credentials.
    . (Release-Function 'Expected-Signer')
    $signer = Expected-Signer
    Assert ($signer -cmatch '^[a-f0-9]{64}$') 'Expected-Signer did not resolve a fingerprint'
    $sourceRoot = $Root
    $Root = $scratch
    New-Item -ItemType Directory -Path (Join-Path $scratch 'clients/android') | Out-Null
    Set-Content (Join-Path $scratch 'clients/android/release-signer.sha256') 'invalid'
    $rejected = $false
    try { Expected-Signer | Out-Null } catch { $rejected = $true }
    Assert $rejected 'Invalid signing policy was accepted'
    $Root = $sourceRoot

    # C3: execute package discovery with the release script's own package scopes.
    # Existing ignored deployment outputs (including restricted directories) are
    # outside these scopes; every production Go source directory is included.
    $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $Root 'scripts/release-local.ps1'), [ref]$null, [ref]$null)
    $scopeAssignment = $ast.Find({ param($node) $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$GoPackages' }, $true)
    . ([scriptblock]::Create($scopeAssignment.Extent.Text))
    Push-Location $Root
    try { $packages = @(go list @GoPackages); Assert ($LASTEXITCODE -eq 0) 'Release package discovery failed' }
    finally { Pop-Location }
    foreach ($name in @('internal/gateway/gatewaycore', 'nodes/windows', 'server/lan', 'server/public')) {
        Assert (@($packages | Where-Object { $_.EndsWith('/' + $name) }).Count -eq 1) "Missing production package $name"
    }

    # M1: same executable, different full configuration paths, plus a stale PID
    # snapshot. Only the selected argument vector may be terminated.
    $bin = Join-Path $scratch 'tunnel executable'
    New-Item -ItemType Directory -Path $bin | Out-Null
    $exe = Join-Path $bin 'frpc.exe'
    $fixture = Join-Path $scratch 'fixture.go'
    Set-Content $fixture 'package main; import "time"; func main() { for { time.Sleep(time.Hour) } }'
    go build -o $exe $fixture
    Assert ($LASTEXITCODE -eq 0) 'Process fixture did not build'
    $config = Join-Path $scratch 'gateway A/config.toml'
    $otherConfig = $config + '.other'
    $component = [pscustomobject]@{ executable=$exe; arguments=@('-c', $config) }
    function Start-Fixture([string]$configuration) {
        $process = Start-Process -FilePath $exe -ArgumentList @('-c', ('"' + $configuration + '"')) -WindowStyle Hidden -PassThru
        $processes.Add($process)
        return $process
    }
    $first = Start-Fixture $config
    $other = Start-Fixture $otherConfig
    $snapshot = @(Get-ComponentProcess $component)
    Assert ($snapshot.Count -eq 1 -and $snapshot[0].ProcessId -eq $first.Id) 'Selected another tunnel'
    $stale = $snapshot[0] | Select-Object *
    $stale.CreationDate = $stale.CreationDate.AddSeconds(-1)
    $rejected = $false
    try { Stop-ComponentProcess $stale $component } catch { $rejected = $true }
    Assert ($rejected -and -not $first.HasExited) 'Stale process identity was not rejected'
    $parsed = [RemoteEverything.ProcessCommandLine]::Parse('"C:\Program Files\frpc.exe" -c "C:\config path\a.toml" ""')
    Assert ($parsed.Count -eq 4 -and $parsed[3] -eq '') 'Quoted or empty arguments were lost'
    $duplicate = Start-Fixture $config

    $installation = 'a' * 64
    $runtime = Get-Content (Join-Path $Root 'skills/remote-everything-install/assets/runtime.minimal.json') -Raw | ConvertFrom-Json
    $runtime.installation_id = $installation
    $runtime.root = $scratch
    $runtime.platform = 'windows'
    $runtime.mode = 'public'
    $runtime.components = @([pscustomobject]@{
        id='frpc-a'; managed=$true; executable=$exe; arguments=$component.arguments
        sha256=('b' * 64); working_directory=$scratch; log=(Join-Path $scratch 'frpc.log')
        manager=@{type='scheduled-task'; id="\RemoteEverything\$installation\frpc-a"}
        expected=@{}; observed=@{}; verification=@{}
    })
    $runtimePath = Join-Path $scratch 'runtime.json'
    $runtime | ConvertTo-Json -Depth 10 | Set-Content $runtimePath
    $global:MaintenancetaskCalls = [Collections.Generic.List[string]]::new()
    $global:MaintenancesshCalls = [Collections.Generic.List[string]]::new()
    function Get-ScheduledTask { param($TaskPath, $TaskName) return @{TaskPath=$TaskPath; TaskName=$TaskName} }
    function Stop-ScheduledTask { param($TaskPath, $TaskName) $global:MaintenancetaskCalls.Add("stop:$TaskPath$TaskName") }
    function Start-ScheduledTask {
        param($TaskPath, $TaskName)
        $global:MaintenancetaskCalls.Add("start:$TaskPath$TaskName")
        Assert $first.HasExited 'Recovery did not stop the selected FRPC'
        Assert $duplicate.HasExited 'Recovery left a duplicate of the selected FRPC'
        Assert (-not $other.HasExited) 'Recovery stopped another FRPC'
        Start-Fixture $config | Out-Null
    }
    function ssh {
        $global:MaintenancesshCalls.Add(($args -join ' '))
        $global:LASTEXITCODE = 0
        if (($args -join ' ') -match 'curl ') { '200' }
    }
    function Start-Sleep { param($Seconds) }
    $python = if ($env:MAINTENANCE_PYTHON) { $env:MAINTENANCE_PYTHON } else { 'python' }
    $recovery = Join-Path $Root 'scripts/recover-frp-tunnel.ps1'
    $rejected = $false
    try { & $recovery -InstallationId ('c' * 64) -RuntimePath $runtimePath -ComponentId frpc-a -ServerAlias fixture -TunnelProbe 'http://127.0.0.1:34567/__remote_everything/apps' -Python $python }
    catch { $rejected = $true }
    Assert ($rejected -and $global:MaintenancetaskCalls.Count -eq 0 -and $global:MaintenancesshCalls.Count -eq 0) 'Mismatched installation reached mutations'
    & (Join-Path $Root 'scripts/recover-frp-tunnel.ps1') -InstallationId $installation -RuntimePath $runtimePath -ComponentId frpc-a -ServerAlias fixture -TunnelProbe 'http://127.0.0.1:34567/__remote_everything/apps' -Python $python
    Assert (-not $other.HasExited) 'Other tunnel was terminated'
    Assert ($global:MaintenancetaskCalls.Count -eq 2) 'Unexpected scheduled task mutation'
    Assert ($global:MaintenancesshCalls.Count -eq 3) 'Unexpected remote operations'

    # C2: drive the actual Windows workflow block through each native failure.
    $workflow = Get-Content (Join-Path $Root '.github/workflows/nodes.yml') -Raw
    $start = $workflow.IndexOf('          $unformatted = gofmt -l .')
    $end = $workflow.IndexOf('  unix:', $start)
    $ci = [scriptblock]::Create(($workflow.Substring($start, $end-$start) -replace '(?m)^          ', ''))
    $global:Maintenancecommands = [Collections.Generic.List[string]]::new()
    function gofmt { $global:Maintenancecommands.Add('gofmt'); $global:LASTEXITCODE = if ($global:MaintenancefailAt -eq 'gofmt') { 23 } else { 0 } }
    function go { $global:Maintenancecommands.Add([string]$args[0]); $global:LASTEXITCODE = if ($global:MaintenancefailAt -eq $args[0]) { 23 } else { 0 } }
    foreach ($global:MaintenancefailAt in @('gofmt', 'vet', 'test', 'build')) {
        $global:Maintenancecommands.Clear()
        $rejected = $false
        try { & $ci } catch { $rejected = $true }
        Assert ($rejected -and $global:Maintenancecommands[$global:Maintenancecommands.Count-1] -eq $global:MaintenancefailAt) "CI continued after failed $global:MaintenancefailAt"
    }
    Write-Output '{"ok":true,"suite":"windows-maintenance","checks":["release-toolchain","signer-source","release-package-scope","tunnel-isolation","stale-pid","ci-fail-fast"]}'
} finally {
    foreach ($process in $processes) {
        if (-not $process.HasExited) { $process.Kill(); $process.WaitForExit() }
        $process.Dispose()
    }
    $resolvedScratch = [IO.Path]::GetFullPath($scratch)
    $temporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $resolvedScratch.StartsWith($temporaryRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'Invalid test cleanup path' }
    Remove-Item -LiteralPath $resolvedScratch -Recurse -Force
}

# The failure-injection loop above leaves $LASTEXITCODE at the last mock's
# failure code; the runner turns any non-zero leftover into a failed step.
exit 0

param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-z0-9][a-z0-9._-]{0,63}$')]
    [string]$Id
)

$ErrorActionPreference = 'Stop'
$stateRoot = Join-Path $env:LOCALAPPDATA 'RemoteEverything'
$registryPath = Join-Path $stateRoot 'apps.json'
if (-not (Test-Path -LiteralPath $registryPath)) { throw 'Application registry was not found.' }
$registry = Get-Content -LiteralPath $registryPath -Raw | ConvertFrom-Json
$existing = @($registry.apps | Where-Object id -eq $Id)
if ($existing.Count -ne 1) { throw 'Application was not found.' }
$value = [ordered]@{ version = 1; apps = @($registry.apps | Where-Object id -ne $Id | Sort-Object id) }
$temporary = "$registryPath.tmp"
[IO.File]::WriteAllText($temporary, ($value | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
Move-Item -LiteralPath $temporary -Destination $registryPath -Force
$enabledPath = Join-Path (Join-Path $stateRoot 'enabled') $Id
if (Test-Path -LiteralPath $enabledPath) { Remove-Item -LiteralPath $enabledPath -Force }
$value.apps | ConvertTo-Json -Depth 8

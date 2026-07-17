param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-z0-9][a-z0-9._-]{0,63}$')]
    [string]$Id,
    [Parameter(Mandatory = $true)]
    [string]$Name,
    [string]$Description = '',
    [string]$Icon = '',
    [ValidatePattern('^#[0-9A-Fa-f]{6}$')]
    [string]$Accent = '#2563eb',
    [Parameter(Mandatory = $true)]
    [uri]$WebUrl,
    [Parameter(Mandatory = $true)]
    [uri]$ProxyUrl,
    [Parameter(Mandatory = $true)]
    [string]$Command,
    [string[]]$Arguments = @(),
    [string]$StopCommand = '',
    [string[]]$StopArguments = @(),
    [Parameter(Mandatory = $true)]
    [string]$Probe,
    [string]$WorkDir = '',
    [bool]$Enabled = $true
)

$ErrorActionPreference = 'Stop'
if ($WebUrl.Scheme -ne 'https') { throw 'Application web URL must use HTTPS.' }
if ($ProxyUrl.Scheme -ne 'http' -or $ProxyUrl.Host -notin @('127.0.0.1', 'localhost')) { throw 'Application proxy URL must use loopback HTTP.' }
$probeUri = $null
if (-not [uri]::TryCreate("tcp://$Probe", [UriKind]::Absolute, [ref]$probeUri) -or $probeUri.Port -lt 1 -or $probeUri.Port -gt 65535) { throw 'Invalid application probe.' }
if ($WorkDir) {
    if (-not (Test-Path -LiteralPath $WorkDir -PathType Container)) { throw 'Invalid working directory.' }
    $WorkDir = (Resolve-Path -LiteralPath $WorkDir).Path
}
$commandPath = (Resolve-Path -LiteralPath $Command).Path
$stopCommandPath = ''
if ($StopCommand) { $stopCommandPath = (Resolve-Path -LiteralPath $StopCommand).Path }
if (-not $Icon) { $Icon = $Name.Substring(0, 1).ToUpperInvariant() }
if ($Icon.Length -gt 4) { throw 'Application icon text is too long.' }

$stateRoot = Join-Path $env:LOCALAPPDATA 'AgentRemote'
$enabledRoot = Join-Path $stateRoot 'enabled'
$registryPath = Join-Path $stateRoot 'apps.json'
New-Item -ItemType Directory -Path $stateRoot, $enabledRoot -Force | Out-Null
if (Test-Path -LiteralPath $registryPath) {
    $registry = Get-Content -LiteralPath $registryPath -Raw | ConvertFrom-Json
}
else {
    $registry = [pscustomobject]@{ version = 1; apps = @() }
}
$apps = @($registry.apps | Where-Object { $_.id -ne $Id })
$apps += [pscustomobject]@{
    id = $Id
    name = $Name
    description = $Description
    icon = $Icon
    accent = $Accent.ToLowerInvariant()
    web_url = $WebUrl.AbsoluteUri
    proxy_url = $ProxyUrl.AbsoluteUri
    command = $commandPath
    arguments = @($Arguments)
    stop_command = $stopCommandPath
    stop_arguments = @($StopArguments)
    probe = $Probe
    workdir = $WorkDir
}
$value = [ordered]@{ version = 1; apps = @($apps | Sort-Object id) }
$temporary = "$registryPath.tmp"
[IO.File]::WriteAllText($temporary, ($value | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
Move-Item -LiteralPath $temporary -Destination $registryPath -Force

$enabledPath = Join-Path $enabledRoot $Id
if ($Enabled) {
    if (-not (Test-Path -LiteralPath $enabledPath)) { New-Item -ItemType File -Path $enabledPath | Out-Null }
}
elseif (Test-Path -LiteralPath $enabledPath) {
    Remove-Item -LiteralPath $enabledPath -Force
}
if (Get-ScheduledTask -TaskName 'AgentRemote-Apps' -ErrorAction SilentlyContinue) {
    Start-ScheduledTask -TaskName 'AgentRemote-Apps'
}
$value.apps | Where-Object id -eq $Id | ConvertTo-Json -Depth 8

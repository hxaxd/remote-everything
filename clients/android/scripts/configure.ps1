param(
    [Parameter(Mandatory = $true)]
    [string]$BundleDir
)

$ErrorActionPreference = 'Stop'

$androidRoot = Split-Path -Parent $PSScriptRoot
$bundle = (Resolve-Path -LiteralPath $BundleDir).Path
$config = Get-Content -LiteralPath (Join-Path $bundle 'config.json') -Raw | ConvertFrom-Json
if ($config.public_host -notmatch '^[A-Za-z0-9.-]+$') { throw 'Invalid public host.' }

$p12 = Join-Path $bundle 'bootstrap-client.p12'
foreach ($file in @($p12)) {
    if (-not (Test-Path -LiteralPath $file)) { throw "Missing bundle file: $file" }
}

$certificate = [Security.Cryptography.X509Certificates.X509Certificate2]::new(
    $p12,
    [string]$config.bootstrap_password,
    [Security.Cryptography.X509Certificates.X509KeyStorageFlags]::EphemeralKeySet
)
$fingerprint = $certificate.GetCertHashString([Security.Cryptography.HashAlgorithmName]::SHA256).ToLowerInvariant()
if ($fingerprint -ne [string]$config.bootstrap_fingerprint) { throw 'Bootstrap certificate fingerprint mismatch.' }

$rawResources = Join-Path $androidRoot 'app\src\main\res\raw'
New-Item -ItemType Directory -Path $rawResources -Force | Out-Null
Copy-Item -LiteralPath $p12 -Destination (Join-Path $rawResources 'bootstrap_client.p12') -Force

$hostName = [string]$config.public_host
$origin = "https://$hostName"
$utf8 = [Text.UTF8Encoding]::new($false)

$androidProperties = Join-Path $androidRoot 'remote-everything.properties'
$androidLines = @(
    "gatewayHost=$hostName"
    "gatewayOrigin=$origin"
    "controlToken=$($config.control_token)"
    "bootstrapPassword=$($config.bootstrap_password)"
    "bootstrapFingerprint=$($config.bootstrap_fingerprint)"
)
[IO.File]::WriteAllLines($androidProperties, $androidLines, $utf8)

[pscustomobject]@{
    public_host = $hostName
    bootstrap_fingerprint = $fingerprint
    android = 'configured'
} | ConvertTo-Json

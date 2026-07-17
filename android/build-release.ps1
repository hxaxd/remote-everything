$ErrorActionPreference = 'Stop'

$projectDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$signingDir = Join-Path $env:LOCALAPPDATA 'AgentRemote\signing'
$keyStore = Join-Path $signingDir 'android-release.jks'
$passwordFile = Join-Path $signingDir 'android-release.password'
$androidSdk = @($env:ANDROID_HOME, $env:ANDROID_SDK_ROOT, (Join-Path $env:LOCALAPPDATA 'Android\Sdk')) |
    Where-Object { $_ -and (Test-Path -LiteralPath $_) } |
    Select-Object -First 1
if (-not $androidSdk) { throw 'Android SDK was not found.' }
$sdkProperty = $androidSdk.Replace('\', '/').Replace(':', '\:')
Set-Content -LiteralPath (Join-Path $projectDir 'local.properties') -Value "sdk.dir=$sdkProperty"

$javaHome = @($env:JAVA_HOME, 'C:\Program Files\Java\jdk-23') |
    Where-Object { $_ -and (Test-Path -LiteralPath (Join-Path $_ 'bin\keytool.exe')) } |
    Select-Object -First 1
if (-not $javaHome) { throw 'A Java development kit was not found.' }
$keytool = Join-Path $javaHome 'bin\keytool.exe'

New-Item -ItemType Directory -Force $signingDir | Out-Null
if (-not (Test-Path -LiteralPath $passwordFile)) {
    $bytes = New-Object byte[] 32
    [Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    [Convert]::ToHexString($bytes).ToLowerInvariant() | Set-Content -LiteralPath $passwordFile -NoNewline
}
$password = (Get-Content -LiteralPath $passwordFile -Raw).Trim()
if (-not (Test-Path -LiteralPath $keyStore)) {
    & $keytool -genkeypair -keystore $keyStore -storepass $password -keypass $password -alias agent-remote -keyalg RSA -keysize 4096 -validity 36500 -dname 'CN=Agent Remote, OU=Personal, O=Agent Remote, C=CN'
    if ($LASTEXITCODE -ne 0) { throw 'Android signing key creation failed.' }
}

$env:JAVA_HOME = $javaHome
$env:AGENT_REMOTE_ANDROID_KEYSTORE = $keyStore
$env:AGENT_REMOTE_ANDROID_STORE_PASSWORD = $password
$env:AGENT_REMOTE_ANDROID_KEY_PASSWORD = $password
& (Join-Path $projectDir 'gradlew.bat') --no-daemon --console=plain :app:assembleRelease
if ($LASTEXITCODE -ne 0) { throw 'Android release build failed.' }

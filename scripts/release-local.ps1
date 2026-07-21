[CmdletBinding()]
param(
    [ValidateSet('Validate', 'Build', 'Draft', 'Publish')]
    [string]$Mode = 'Build',
    [switch]$CreateTag,
    [switch]$SkipValidation,
    [switch]$ClobberAssets,
    [string]$SigningKey = (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'key\android-release-v2.jks'),
    [string]$SigningPasswordFile = (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'key\android-release-v2.password.clixml')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$Root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$Release = Get-Content (Join-Path $Root 'clients\release.json') -Raw | ConvertFrom-Json
$Version = [string]$Release.versionName
$BuildNumber = [int]$Release.buildNumber
$Tag = "v$Version"
$Output = Join-Path $Root "dist\release-$Version"
$Assets = @(
    'app-release.apk',
    'remote-everything-control-windows-amd64.exe',
    'remote-everything-control-windows-arm64.exe',
    'remote-everything-control-linux-amd64',
    'remote-everything-control-linux-arm64',
    'remote-everything-control-macos-amd64',
    'remote-everything-control-macos-arm64',
    'remote-everything-lan-server-windows-amd64.exe',
    'remote-everything-lan-server-windows-arm64.exe',
    'remote-everything-lan-server-linux-amd64',
    'remote-everything-lan-server-linux-arm64',
    'remote-everything-lan-server-macos-amd64',
    'remote-everything-lan-server-macos-arm64',
    'remote-everything-gateway-linux-amd64',
    'remote-everything-gateway-linux-arm64'
)

function Step([string]$Text) { Write-Host "`n==> $Text" -ForegroundColor Cyan }
function Run([scriptblock]$Command, [string]$Failure) {
    & $Command
    if ($LASTEXITCODE -ne 0) { throw "$Failure (exit code $LASTEXITCODE)" }
}
function Need([string]$Command) {
    if (-not (Get-Command $Command -ErrorAction SilentlyContinue)) { throw "Required command is unavailable: $Command" }
}
function Android-Sdk {
    foreach ($candidate in @($env:ANDROID_HOME, $env:ANDROID_SDK_ROOT, (Join-Path $env:LOCALAPPDATA 'Android\Sdk'))) {
        if ($candidate -and (Test-Path $candidate)) { return [IO.Path]::GetFullPath($candidate) }
    }
    $properties = Join-Path $Root 'clients\android\local.properties'
    if (Test-Path $properties) {
        $line = Get-Content $properties | Where-Object { $_ -match '^sdk\.dir=' } | Select-Object -First 1
        if ($line) {
            $candidate = ($line -replace '^sdk\.dir=', '') -replace '\\:', ':' -replace '\\\\', '\'
            if (Test-Path $candidate) { return [IO.Path]::GetFullPath($candidate) }
        }
    }
    throw 'Android SDK was not found. Configure ANDROID_HOME or clients/android/local.properties.'
}
function Apk-Signer([string]$Sdk) {
    $found = @(Get-ChildItem (Join-Path $Sdk 'build-tools') -Recurse -File |
        Where-Object Name -in @('apksigner', 'apksigner.bat') |
        Sort-Object { [version]$_.Directory.Name } -Descending)
    if (-not $found) { throw 'apksigner was not found in Android SDK build-tools.' }
    $found[0].FullName
}
function Expected-Signer {
    $source = Get-Content (Join-Path $Root 'clients\android\app\src\main\java\com\remoteeverything\app\AppUpdater.kt') -Raw
    $match = [regex]::Match($source, 'OFFICIAL_SIGNER_SHA256\s*=\s*"([a-f0-9]{64})"')
    if (-not $match.Success) { throw 'Could not read OFFICIAL_SIGNER_SHA256 from AppUpdater.kt.' }
    $match.Groups[1].Value
}

function Validate-Repository {
    Step "Validate release metadata $Version ($BuildNumber)"
    Run { python clients/contracts/validate_contracts.py } 'Contract validation failed'
    Run { python clients/validate_versions.py } 'Client version validation failed'
    Run { python clients/harmony/audit_source.py } 'HarmonyOS source audit failed'
    foreach ($file in @(
        'clients/harmony/AppScope/app.json5', 'clients/harmony/build-profile.json5',
        'clients/harmony/hvigor/hvigor-config.json5', 'clients/harmony/oh-package.json5',
        'clients/harmony/entry/oh-package.json5', 'clients/harmony/entry/src/main/module.json5',
        'clients/harmony/entry/src/main/resources/base/profile/main_pages.json'
    )) { Run { python -m json.tool $file *> $null } "Invalid JSON manifest: $file" }

    Step 'Validate repository assets and deployment scripts'
    $tracked = @(git ls-files | Where-Object { $_ -match '\.(p12|pfx|jks|keystore|key|key\.pem)$|(^|/)AGENTS\.local\.md$|(^|/)local\.properties$' })
    if ($tracked) { throw "Tracked credential or local files:`n$($tracked -join "`n")" }
    Run { python skills/validate.py } 'Skill validation failed'
    Run { python -m unittest skills/remote-everything-install/scripts/test_runtime.py skills/remote-everything-install/scripts/test_render.py skills/remote-everything-install/scripts/test_validate_deployment.py skills/remote-everything-install/scripts/test_inspect_443.py } 'Deployment tests failed'
    Run { python skills/remote-everything-install/scripts/runtime.py validate skills/remote-everything-install/assets/runtime.minimal.json } 'Minimal runtime validation failed'
    Run { python skills/remote-everything-install/scripts/runtime.py validate skills/remote-everything-install/assets/runtime.full.json } 'Full runtime validation failed'

    Step 'Run Go checks and Windows node probes'
    $unformatted = @(gofmt -l internal nodes server)
    if ($unformatted) { throw "Unformatted Go files:`n$($unformatted -join "`n")" }
    Run { go vet ./... } 'go vet failed'
    Run { go test ./... } 'Go tests failed'
    Need staticcheck
    Need govulncheck
    $gitleaksCommand = Get-Command gitleaks -ErrorAction SilentlyContinue
    $gitleaksPath = if ($gitleaksCommand) { $gitleaksCommand.Source } else { $null }
    if (-not $gitleaksPath) {
        $localGitleaks = Join-Path $Root '.runtime\bin\gitleaks-8.30.1\gitleaks.exe'
        if (Test-Path $localGitleaks -PathType Leaf) { $gitleaksPath = $localGitleaks }
    }
    if (-not $gitleaksPath) { throw 'gitleaks 8.30.1 is required for the full-history secret scan.' }
    Run { staticcheck ./... } 'staticcheck failed'
    Run { govulncheck ./... } 'govulncheck failed'
    Run { & $gitleaksPath git . --log-opts=--all --redact=100 --no-banner } 'Full-history secret scan failed'
    Push-Location (Join-Path $Root 'nodes\windows')
    try { Run { .\tests\run.ps1 } 'Windows node integration tests failed' } finally { Pop-Location }

    Step 'Run Android unit tests, lint, and debug build'
    $sdk = Android-Sdk
    $oldHome, $oldRoot = $env:ANDROID_HOME, $env:ANDROID_SDK_ROOT
    $env:ANDROID_HOME = $sdk; $env:ANDROID_SDK_ROOT = $sdk
    Push-Location (Join-Path $Root 'clients\android')
    try { Run { .\gradlew.bat --no-daemon --console=plain :app:testDebugUnitTest :app:lintDebug :app:assembleDebug } 'Android validation failed' }
    finally { Pop-Location; $env:ANDROID_HOME = $oldHome; $env:ANDROID_SDK_ROOT = $oldRoot }

    if ($IsMacOS -and (Get-Command xcodebuild -ErrorAction SilentlyContinue) -and (Get-Command xcodegen -ErrorAction SilentlyContinue)) {
        Step 'Run native iOS tests and analyzer'
        Push-Location (Join-Path $Root 'clients\ios')
        try {
            Run { xcodegen generate } 'XcodeGen failed'
            Run { xcodebuild test -project RemoteEverything.xcodeproj -scheme RemoteEverything -destination 'platform=iOS Simulator,name=iPhone 16 Pro' CODE_SIGNING_ALLOWED=NO } 'iOS tests failed'
            Run { xcodebuild analyze -project RemoteEverything.xcodeproj -scheme RemoteEverything -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO } 'iOS analysis failed'
        } finally { Pop-Location }
    } else { Write-Warning 'Native iOS checks skipped: macOS with Xcode and XcodeGen is required.' }
}

function Build-Go {
    Step 'Build 14 cross-platform Go assets'
    New-Item -ItemType Directory -Force $Output | Out-Null
    $oldOs, $oldArch, $oldCgo = $env:GOOS, $env:GOARCH, $env:CGO_ENABLED
    try {
        $targets = @(
            @('windows','amd64','windows','windows','.exe','-s -w -H=windowsgui'),
            @('windows','arm64','windows','windows','.exe','-s -w -H=windowsgui'),
            @('linux','amd64','linux','linux','','-s -w'), @('linux','arm64','linux','linux','','-s -w'),
            @('darwin','amd64','macos','macos','','-s -w'), @('darwin','arm64','macos','macos','','-s -w')
        )
        foreach ($target in $targets) {
            $goos,$arch,$node,$assetOs,$suffix,$flags = $target
            $env:GOOS=$goos; $env:GOARCH=$arch; $env:CGO_ENABLED='0'
            Push-Location (Join-Path $Root "nodes\$node")
            try { $path=Join-Path $Output "remote-everything-control-$assetOs-$arch$suffix"; Run { go build -trimpath -ldflags $flags -o $path . } "Node build failed: $goos/$arch" } finally { Pop-Location }
            Push-Location (Join-Path $Root 'server\lan')
            try { $path=Join-Path $Output "remote-everything-lan-server-$assetOs-$arch$suffix"; Run { go build -trimpath -ldflags '-s -w' -o $path . } "LAN build failed: $goos/$arch" } finally { Pop-Location }
        }
        foreach ($arch in @('amd64','arm64')) {
            $env:GOOS='linux'; $env:GOARCH=$arch; $env:CGO_ENABLED='0'
            Push-Location (Join-Path $Root 'server\public')
            try { $path=Join-Path $Output "remote-everything-gateway-linux-$arch"; Run { go build -trimpath -ldflags '-s -w' -o $path . } "Gateway build failed: linux/$arch" } finally { Pop-Location }
        }
    } finally { $env:GOOS=$oldOs; $env:GOARCH=$oldArch; $env:CGO_ENABLED=$oldCgo }
}

function Build-Android {
    Step 'Build and verify signed Android APK'
    foreach ($path in @($SigningKey,$SigningPasswordFile)) { if (-not (Test-Path $path -PathType Leaf)) { throw "Missing signing material: $path" } }
    $secure = Import-Clixml $SigningPasswordFile
    if ($secure -isnot [securestring]) { throw 'Signing password file is not a DPAPI-protected SecureString.' }
    $credential = [Net.NetworkCredential]::new('', $secure); $password = $credential.Password
    $expected = Expected-Signer; $sdk = Android-Sdk
    $env:RE_LOCAL_SIGN_PASSWORD = $password
    try {
        $details = keytool -list -v -keystore $SigningKey -alias agent-remote -storepass:env RE_LOCAL_SIGN_PASSWORD 2>&1 | Out-String
        if ($LASTEXITCODE) { throw 'Signing key could not be opened.' }
        $match = [regex]::Match($details, '(?im)^\s*SHA256:\s*([0-9A-F:]+)\s*$')
        if (-not $match.Success) { throw 'Signing key fingerprint could not be parsed.' }
        $actual = $match.Groups[1].Value.Replace(':','').ToLowerInvariant()
        if ($actual -ne $expected) { throw "Key fingerprint $actual does not match source $expected." }

        $old = @($env:ANDROID_HOME,$env:ANDROID_SDK_ROOT,$env:REMOTE_EVERYTHING_ANDROID_KEYSTORE,$env:REMOTE_EVERYTHING_ANDROID_STORE_PASSWORD,$env:REMOTE_EVERYTHING_ANDROID_KEY_PASSWORD)
        $env:ANDROID_HOME=$sdk; $env:ANDROID_SDK_ROOT=$sdk; $env:REMOTE_EVERYTHING_ANDROID_KEYSTORE=[IO.Path]::GetFullPath($SigningKey)
        $env:REMOTE_EVERYTHING_ANDROID_STORE_PASSWORD=$password; $env:REMOTE_EVERYTHING_ANDROID_KEY_PASSWORD=$password
        Push-Location (Join-Path $Root 'clients\android')
        try { Run { .\gradlew.bat --no-daemon --console=plain :app:assembleRelease } 'Signed Android build failed' }
        finally {
            Pop-Location
            $env:ANDROID_HOME=$old[0]; $env:ANDROID_SDK_ROOT=$old[1]; $env:REMOTE_EVERYTHING_ANDROID_KEYSTORE=$old[2]
            $env:REMOTE_EVERYTHING_ANDROID_STORE_PASSWORD=$old[3]; $env:REMOTE_EVERYTHING_ANDROID_KEY_PASSWORD=$old[4]
        }
        $apk = Join-Path $Root 'clients\android\app\build\outputs\apk\release\app-release.apk'
        if (-not (Test-Path $apk -PathType Leaf)) { throw 'Signed APK was not produced.' }
        $target = Join-Path $Output 'app-release.apk'; Copy-Item $apk $target -Force
        $signer = Apk-Signer $sdk; Run { & $signer verify $target } 'APK signature verification failed'
        $cert = & $signer verify --print-certs $target 2>&1 | Out-String
        $match = [regex]::Match($cert, '(?im)SHA-256 digest:\s*([0-9A-Fa-f:]+)')
        if (-not $match.Success -or $match.Groups[1].Value.Replace(':','').ToLowerInvariant() -ne $expected) { throw 'APK signer fingerprint does not match source.' }
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip=[IO.Compression.ZipFile]::OpenRead($target)
        try { if ($zip.Entries | Where-Object FullName -match '(?i)\.p12$|(^|/)remote-everything\.properties$') { throw 'Deployment credentials were packaged in the APK.' } } finally { $zip.Dispose() }
    } finally { Remove-Item Env:RE_LOCAL_SIGN_PASSWORD -ErrorAction SilentlyContinue; $password=$null; $credential=$null; $secure=$null }
}

function Checksums {
    Step 'Verify assets and write SHA256SUMS'
    foreach ($name in $Assets) { $path=Join-Path $Output $name; if (-not (Test-Path $path -PathType Leaf) -or (Get-Item $path).Length -eq 0) { throw "Missing asset: $name" } }
    $extra=@(Get-ChildItem $Output -File | Where-Object Name -notin ($Assets + 'SHA256SUMS'))
    if ($extra) { throw "Unexpected release files:`n$($extra.Name -join "`n")" }
    $lines=foreach($name in $Assets){ "$(Get-FileHash (Join-Path $Output $name) -Algorithm SHA256 | ForEach-Object Hash | ForEach-Object ToLowerInvariant)  $name" }
    Set-Content (Join-Path $Output 'SHA256SUMS') $lines -Encoding utf8NoBOM
}

function Git-State {
    $dirty=git status --porcelain --untracked-files=no; if($dirty){throw "Commit tracked changes before publishing:`n$($dirty -join "`n")"}
    $head=git rev-parse HEAD
    if($CreateTag){
        $branch=git branch --show-current; if($branch -ne 'main'){throw "-CreateTag requires main, not $branch."}
        git show-ref --verify --quiet "refs/tags/$Tag"; if($LASTEXITCODE -eq 0){throw "Tag $Tag already exists."}
        Run { git tag -a $Tag $head -m "Remote Everything $Version" } "Could not create $Tag"
        Run { git push origin "refs/tags/$Tag" } "Could not push $Tag"
    }
    $tagHead=git rev-parse "$Tag^{}" 2>$null; if($LASTEXITCODE -ne 0 -or $tagHead -ne $head){throw "Tag $Tag must point to HEAD $head."}
    $remote=git ls-remote --tags origin "refs/tags/$Tag^{}"; if(-not $remote -or ($remote -split '\s+')[0] -ne $head){throw "Remote $Tag does not point to HEAD."}
}
function Upload-Release {
    Need gh; Git-State; Step "$Mode GitHub release $Tag"
    $paths=@($Assets + 'SHA256SUMS' | ForEach-Object { Join-Path $Output $_ })
    gh release view $Tag *> $null; $exists=$LASTEXITCODE -eq 0
    if(-not $exists){
        $args=@('release','create',$Tag)+$paths+@('--verify-tag','--generate-notes','--title',$Tag)
        if($Mode -eq 'Draft'){$args+='--draft'}
        Run { gh @args } "Could not create release $Tag"; return
    }
    $release=gh release view $Tag --json isDraft | ConvertFrom-Json
    if(-not $release.isDraft){throw "Published release $Tag is immutable."}
    if(-not $ClobberAssets){throw "Draft $Tag exists; pass -ClobberAssets to replace assets."}
    Run { gh release upload $Tag @paths --clobber } "Could not upload $Tag assets"
    if($Mode -eq 'Publish'){Run { gh release edit $Tag --draft=false --latest } "Could not publish $Tag"}
}

Push-Location $Root
try {
    foreach($command in @('git','go','gofmt','python','java','keytool')){Need $command}
    if(-not $SkipValidation){Validate-Repository}
    if($Mode -ne 'Validate'){
        Build-Go; Build-Android; Checksums
        if($Mode -in @('Draft','Publish')){Upload-Release}
        Write-Host "`nRelease assets ready: $Output" -ForegroundColor Green
    }
} finally { Pop-Location }

$ErrorActionPreference = 'Stop'

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "assertion failed: $Message" }
}

function Get-FreePort {
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $listener.Start()
    try { return ([Net.IPEndPoint]$listener.LocalEndpoint).Port }
    finally { $listener.Stop() }
}

function Test-Port([int]$Port) {
    $client = [Net.Sockets.TcpClient]::new()
    try { return $client.ConnectAsync('127.0.0.1', $Port).Wait(150) -and $client.Connected }
    catch { return $false }
    finally { $client.Dispose() }
}

function Wait-Port([int]$Port, [bool]$Open = $true) {
    for ($attempt = 0; $attempt -lt 100; $attempt++) {
        if ((Test-Port $Port) -eq $Open) { return }
        Start-Sleep -Milliseconds 100
    }
    throw "port $Port did not become $(if ($Open) { 'open' } else { 'closed' })"
}

function Invoke-Control([string]$Body, [bool]$Authorized = $true, [string]$Method = 'POST') {
    $headers = @{}
    if ($Authorized) { $headers.Authorization = "Bearer $script:token" }
    $request = @{
        Uri = "http://127.0.0.1:$script:controlPort/__local_remote_control"
        Method = $Method
        Headers = $headers
        Body = $Body
        ContentType = 'application/json'
        SkipHttpErrorCheck = $true
    }
    Invoke-WebRequest @request
}

$testsRoot = $PSScriptRoot
$windowsRoot = Split-Path -Parent $testsRoot
$python = Get-Command python -ErrorAction Stop
$go = Get-Command go -ErrorAction Stop
$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) "remote-everything-windows-tests-$([guid]::NewGuid().ToString('N'))"
$stateParent = Join-Path $temporaryRoot 'profile'
$stateRoot = Join-Path $stateParent 'RemoteEverything'
$controlPath = Join-Path $temporaryRoot 'remote-everything-control.exe'
$controlProcess = $null
$oldLocalAppData = $env:LOCALAPPDATA

try {
    New-Item -ItemType Directory -Path $temporaryRoot, $stateParent, $stateRoot | Out-Null
    $appPort = Get-FreePort
    $childPort = Get-FreePort
    $script:token = '01' * 32
    $installationId = '02' * 32

    Push-Location $windowsRoot
    try { & $go.Source build -o $controlPath . }
    finally { Pop-Location }
    Assert-True ($LASTEXITCODE -eq 0) 'temporary control binary builds'
    $repoRoot = Split-Path -Parent (Split-Path -Parent $windowsRoot)
    $genBundlePath = Join-Path $temporaryRoot 'genbundle.exe'
    Push-Location $repoRoot
    try { & $go.Source build -o $genBundlePath ./internal/node/nodecore/testharness/genbundle }
    finally { Pop-Location }
    Assert-True ($LASTEXITCODE -eq 0) 'temporary genbundle binary builds'

    $env:LOCALAPPDATA = $stateParent
    $initialized = (& $controlPath init --state $stateRoot | ConvertFrom-Json)
    Assert-True ($LASTEXITCODE -eq 0 -and $initialized.ok -and $initialized.state -eq $stateRoot) 'init creates node state'
    $script:controlPort = ([Net.IPEndPoint]::Parse($initialized.listen_address)).Port
    Assert-True ($initialized.node_id -match '^[0-9a-f]{64}$') 'init creates a stable node id'
    $initializedAgain = (& $controlPath init --state $stateRoot | ConvertFrom-Json)
    Assert-True ($LASTEXITCODE -eq 0 -and $initializedAgain.ok -and $initializedAgain.listen_address -eq $initialized.listen_address -and $initializedAgain.node_id -eq $initialized.node_id) 'init is idempotent'
    $bootstrapDir = Join-Path $temporaryRoot 'bootstrap'
    & $genBundlePath -bootstrap $bootstrapDir -installation-id $installationId -control-token $script:token
    Assert-True ($LASTEXITCODE -eq 0) 'identity bundle is generated'
    $binding = (& $controlPath binding add --state $stateRoot --bootstrap $bootstrapDir | ConvertFrom-Json)
    Assert-True ($LASTEXITCODE -eq 0 -and $binding.ok -and $binding.installation_id -eq $installationId) 'binding add registers the gateway'
    $bindings = (& $controlPath binding list --state $stateRoot | ConvertFrom-Json)
    Assert-True (@($bindings).Count -eq 1 -and $bindings[0].installation_id -eq $installationId) 'binding list shows the gateway'
    $bindingFiles = @(Get-ChildItem -File -Recurse (Join-Path $stateRoot ('bindings\' + $installationId)))
    Assert-True ($bindingFiles.Count -eq 1 -and $bindingFiles[0].Name -eq 'control-token') 'a binding holds only its control token'

    $controlProcess = Start-Process -FilePath $controlPath `
        -ArgumentList @('serve', '--state', ('"' + $stateRoot + '"')) `
        -WindowStyle Hidden -PassThru
    Wait-Port $controlPort

    $response = Invoke-Control '{"action":"list"}' $false
    Assert-True ($response.StatusCode -eq 401) 'control rejects a missing token'
    $response = Invoke-Control '{}' $true 'GET'
    Assert-True ($response.StatusCode -eq 405) 'control only permits POST'
    $response = Invoke-Control '{' $true
    Assert-True ($response.StatusCode -eq 400) 'control rejects malformed JSON'
    $response = Invoke-Control '{"action":"list","extra":true}' $true
    Assert-True ($response.StatusCode -eq 400) 'control rejects unknown request fields'
    $response = Invoke-Control '{"action":"list"}'
    $body = $response.Content | ConvertFrom-Json
    Assert-True ($body.ok -and @($body.apps).Count -eq 0) 'an empty registry is valid and has no default app'
    $response = Invoke-Control '{"action":"destroy","id":"x"}'
    Assert-True (($response.Content | ConvertFrom-Json).code -eq 'command_not_allowed') 'unknown actions are denied'

    $selection = Invoke-WebRequest -Uri "http://127.0.0.1:$controlPort/" -SkipHttpErrorCheck
    Assert-True ($selection.StatusCode -eq 200 -and $selection.Content -match '尚未选择远程应用') 'proxy has no implicit application'

    $definition = [ordered]@{
        id = 'fixture'
        name = 'Fixture'
        description = ''
        icon = 'F'
        accent = '#2563eb'
        proxy_url = "http://127.0.0.1:$appPort"
        command = $python.Source
        arguments = @((Join-Path $testsRoot 'fixture_server.py'), [string]$appPort, [string]$childPort)
        stop_command = ''
        stop_arguments = @()
        workdir = ''
    }
    $definitionPath = Join-Path $temporaryRoot 'fixture.json'
    [IO.File]::WriteAllText($definitionPath, ($definition | ConvertTo-Json -Depth 5 -Compress), [Text.UTF8Encoding]::new($false))
    $set = (& $controlPath app set --state $stateRoot --file $definitionPath | ConvertFrom-Json)
    Assert-True ($LASTEXITCODE -eq 0 -and $set.ok -and $set.changed) 'app set atomically adds an application'
    $setAgain = (& $controlPath app set --state $stateRoot --file $definitionPath | ConvertFrom-Json)
    Assert-True ($LASTEXITCODE -eq 0 -and $setAgain.ok -and -not $setAgain.changed) 'app set is idempotent'
    $invalidDefinitionPath = Join-Path $temporaryRoot 'invalid.json'
    [IO.File]::WriteAllText($invalidDefinitionPath, '{"id":"fixture","unexpected":true}', [Text.UTF8Encoding]::new($false))
    & $controlPath app set --state $stateRoot --file $invalidDefinitionPath *> $null
    Assert-True ($LASTEXITCODE -ne 0) 'app set rejects an invalid definition'
    $configured = (& $controlPath app list --state $stateRoot | ConvertFrom-Json)
    Assert-True ($LASTEXITCODE -eq 0 -and @($configured.apps).Count -eq 1 -and $configured.apps[0].name -eq 'Fixture') 'invalid app set preserves the registry'
    $body = (Invoke-Control '{"action":"list"}').Content | ConvertFrom-Json
    Assert-True (@($body.apps).Count -eq 1) 'registered application appears in list'
    Assert-True (-not $body.apps[0].enabled -and -not $body.apps[0].running -and $body.apps[0].code -eq 'stopped') 'disabled application reports stopped'
    $beforeStart = Invoke-WebRequest -Uri "http://127.0.0.1:$controlPort/test" -Headers @{ Cookie = 'RemoteEverythingApp=fixture' } -SkipHttpErrorCheck
    Assert-True ($beforeStart.StatusCode -eq 502) 'selected stopped application returns a gateway error'

    $start = (Invoke-Control '{"action":"start","id":"fixture"}').Content | ConvertFrom-Json
    Assert-True ($start.ok -and $start.enabled) 'start enables an application'
    Wait-Port $appPort
    Wait-Port $childPort
    $status = (Invoke-Control '{"action":"status","id":"fixture"}').Content | ConvertFrom-Json
    Assert-True ($status.running -and $status.code -eq 'ready') 'status becomes ready after the probe opens'
    $proxied = Invoke-WebRequest -Uri "http://127.0.0.1:$controlPort/deep?q=1" `
        -Headers @{ Cookie = 'RemoteEverythingApp=fixture; KeepMe=yes' } -SkipHttpErrorCheck
    $proxiedBody = $proxied.Content | ConvertFrom-Json
    Assert-True ($proxied.StatusCode -eq 200 -and $proxiedBody.path -eq '/deep?q=1') 'proxy preserves path and query'
    Assert-True ($proxiedBody.cookie -eq 'KeepMe=yes') 'proxy strips only its routing cookie'
    $missing = (Invoke-Control '{"action":"status","id":"missing"}').Content | ConvertFrom-Json
    Assert-True (-not $missing.ok -and $missing.code -eq 'app_not_found') 'unknown application has a stable error code'

    $stop = (Invoke-Control '{"action":"stop","id":"fixture"}').Content | ConvertFrom-Json
    Assert-True ($stop.ok -and -not $stop.enabled) 'stop disables an application'
    Wait-Port $appPort $false
    Wait-Port $childPort $false
    Assert-True (-not (Test-Port $childPort)) 'stop closes the full managed process tree'

    Invoke-Control '{"action":"start","id":"fixture"}' | Out-Null
    Wait-Port $appPort
    Wait-Port $childPort
    Stop-Process -Id $controlProcess.Id -Force
    $controlProcess.WaitForExit()
    $controlProcess = $null
    Wait-Port $appPort $false
    Wait-Port $childPort $false
    Assert-True (-not (Test-Port $appPort) -and -not (Test-Port $childPort)) 'Windows Job Object closes the managed process tree with the node'

    $removed = (& $controlPath app remove --state $stateRoot fixture | ConvertFrom-Json)
    Assert-True ($LASTEXITCODE -eq 0 -and $removed.ok -and $removed.changed) 'app remove deletes the application'
    $removedAgain = (& $controlPath app remove --state $stateRoot fixture | ConvertFrom-Json)
    Assert-True ($LASTEXITCODE -eq 0 -and $removedAgain.ok -and -not $removedAgain.changed) 'app remove is idempotent'

    Write-Output '{"ok":true,"suite":"windows-node","semantics":27}'
}
finally {
    if ($controlProcess -and -not $controlProcess.HasExited) { Stop-Process -Id $controlProcess.Id -Force -ErrorAction SilentlyContinue }
    $env:LOCALAPPDATA = $oldLocalAppData
    if (Test-Path -LiteralPath $temporaryRoot) { Remove-Item -LiteralPath $temporaryRoot -Recurse -Force }
}

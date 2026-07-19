$ErrorActionPreference = 'Stop'
# 交叉编译云端网关（linux/amd64），产物随 server/ 目录一起 scp 上服务器。
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
Push-Location (Join-Path $root 'gateway')
try {
    $env:GOOS = 'linux'
    $env:GOARCH = 'amd64'
    & go build -trimpath -ldflags '-s -w' -o remote-everything-gateway .
    if ($LASTEXITCODE -ne 0) { throw 'Gateway build failed.' }
}
finally {
    Pop-Location
    Remove-Item Env:\GOOS, Env:\GOARCH -ErrorAction SilentlyContinue
}
Write-Output (Join-Path $root 'gateway\remote-everything-gateway')

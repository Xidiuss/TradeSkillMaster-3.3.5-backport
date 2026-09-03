$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

if (-not (Test-Path (Join-Path $scriptDir "node_modules\fengari"))) {
	Write-Host "FAIL: fengari nie jest zainstalowany w scripts\node_modules (npm install fengari --prefix scripts)." -ForegroundColor Red
	exit 1
}

node (Join-Path $scriptDir "lua-tests\syntax-check.js")
if ($LASTEXITCODE -ne 0) {
	exit 1
}

node (Join-Path $scriptDir "lua-tests\run-tests.js")
if ($LASTEXITCODE -ne 0) {
	exit 1
}

node (Join-Path $scriptDir "lua-tests\run-planner-tests.js")
if ($LASTEXITCODE -ne 0) {
	exit 1
}

node (Join-Path $scriptDir "lua-tests\run-price-log-tests.js")
if ($LASTEXITCODE -ne 0) {
	exit 1
}

node (Join-Path $scriptDir "lua-tests\run-auction-price-log-tests.js")
if ($LASTEXITCODE -ne 0) {
	exit 1
}

node (Join-Path $scriptDir "lua-tests\run-scanner-price-log-tests.js")
if ($LASTEXITCODE -ne 0) {
	exit 1
}

node (Join-Path $scriptDir "lua-tests\run-vendor-fix-tests.js")
if ($LASTEXITCODE -ne 0) {
	exit 1
}

node (Join-Path $scriptDir "lua-tests\run-auctioning-operation-guard-tests.js")
exit $LASTEXITCODE

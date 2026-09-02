$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$projectRoot = Split-Path -Parent $PSScriptRoot
$failures = New-Object System.Collections.Generic.List[string]

function Add-Failure {
	param([string] $Message)
	$script:failures.Add($Message)
}

function Get-TocMetadata {
	param([string] $Path)

	if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
		Add-Failure "Brak pliku $Path."
		return @{}
	}

	$metadata = @{}
	foreach ($line in Get-Content -LiteralPath $Path) {
		if ($line -match '^##\s*([^:]+):\s*(.*)$') {
			$metadata[$matches[1].Trim()] = $matches[2].Trim()
		}
	}
	return $metadata
}

function Test-CompanionAddon {
	param(
		[string] $Folder,
		[string] $SavedVariable
	)

	$tocPath = Join-Path $projectRoot "$Folder\$Folder.toc"
	$corePath = Join-Path $projectRoot "$Folder\Core.lua"
	$metadata = Get-TocMetadata -Path $tocPath

	if ($metadata.ContainsKey("SavedVariables") -and $metadata["SavedVariables"] -ne $SavedVariable) {
		Add-Failure "$Folder zapisuje '$($metadata["SavedVariables"])' zamiast wyłącznie '$SavedVariable'."
	} elseif (-not $metadata.ContainsKey("SavedVariables")) {
		Add-Failure "$Folder nie deklaruje SavedVariables."
	}

	if (-not $metadata.ContainsKey("Dependencies") -or $metadata["Dependencies"] -ne "TradeSkillMaster") {
		Add-Failure "$Folder nie ma obowiązkowej zależności TradeSkillMaster."
	}

	if (-not (Test-Path -LiteralPath $corePath -PathType Leaf)) {
		Add-Failure "Brak pliku $corePath."
	}
}

Test-CompanionAddon -Folder "TSM_PostScan" -SavedVariable "TSMPostScanLogDB"
Test-CompanionAddon -Folder "TSM_CancelScan" -SavedVariable "TSMCancelScanLogDB"

$mainToc = Get-TocMetadata -Path (Join-Path $projectRoot "TradeSkillMaster\TradeSkillMaster.toc")
if ($mainToc.ContainsKey("SavedVariables") -and $mainToc["SavedVariables"].Split(',').Trim() -contains "TSMPriceLogDB") {
	Add-Failure "Główny TradeSkillMaster nadal zapisuje przestarzałą bazę TSMPriceLogDB."
}

if ($failures.Count -gt 0) {
	Write-Host "FAIL: struktura osobnych logów skanów:" -ForegroundColor Red
	foreach ($failure in $failures) {
		Write-Host " - $failure" -ForegroundColor Red
	}
	exit 1
}

Write-Host "PASS: POST i CANCEL mają osobne addony oraz osobne pliki SavedVariables."

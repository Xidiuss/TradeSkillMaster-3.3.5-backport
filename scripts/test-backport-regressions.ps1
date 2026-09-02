$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$projectRoot = Split-Path -Parent $PSScriptRoot
$failures = New-Object System.Collections.Generic.List[string]

function Add-Failure {
	param([string] $Message)
	$script:failures.Add($Message)
}

function Get-LuaFunctionBody {
	param(
		[string[]] $Lines,
		[string] $FunctionName
	)

	$startPattern = '^function private\.' + [regex]::Escape($FunctionName) + '\('
	$collecting = $false
	$body = New-Object System.Collections.Generic.List[string]
	foreach ($line in $Lines) {
		if (-not $collecting) {
			if ($line -match $startPattern) {
				$collecting = $true
				$body.Add($line)
			}
			continue
		}

		$body.Add($line)
		if ($line -match '^end\s*$') {
			return $body -join "`n"
		}
	}

	Add-Failure "Nie znaleziono pełnej funkcji private.$FunctionName()."
	return ""
}

function Test-SearchHandlerLifecycle {
	param(
		[string] $Body,
		[string] $FunctionName,
		[string] $TransitionPattern
	)

	$captureMatch = [regex]::Match($Body, 'local\s+baseFrame\s*=\s*input:GetBaseElement\(\)')
	$transitionMatch = [regex]::Match($Body, $TransitionPattern)
	if (-not $captureMatch.Success) {
		Add-Failure "private.$FunctionName() nie przechwytuje baseFrame z aktywnego inputu."
	}
	if (-not $transitionMatch.Success) {
		Add-Failure "private.$FunctionName() nie zawiera oczekiwanego przejścia widoku."
		return
	}
	if ($captureMatch.Success -and $captureMatch.Index -gt $transitionMatch.Index) {
		Add-Failure "private.$FunctionName() przechwytuje baseFrame dopiero po przejściu widoku."
	}

	$afterTransition = $Body.Substring($transitionMatch.Index + $transitionMatch.Length)
	if ($afterTransition -match '\binput(?::|\.)') {
		Add-Failure "private.$FunctionName() używa inputu po przejściu, które może zwolnić jego widok."
	}
	if ($afterTransition -notmatch '\bbaseFrame(?::|\.)') {
		Add-Failure "private.$FunctionName() nie używa przechwyconego baseFrame po przejściu widoku."
	}
	if ($Body -match 'private\.frame') {
		Add-Failure "private.$FunctionName() nadal zależy od private.frame zerowanego przez OnHide."
	}
}

# Locale tables become read-only when SetTable() attaches LOCALE_TABLE_MT.
# Any later L[...] assignment recreates the exact startup error reported by WoW.
$localeDir = Join-Path $projectRoot "TradeSkillMaster\Locale"
foreach ($localeFile in Get-ChildItem -LiteralPath $localeDir -Filter "*.lua") {
	if ($localeFile.Name -eq "Core.lua") {
		continue
	}

	$registered = $false
	$lineNumber = 0
	foreach ($line in Get-Content -LiteralPath $localeFile.FullName) {
		$lineNumber++
		if ($line -match '^\s*TSM\.Locale\.SetTable\(L\)\s*$') {
			$registered = $true
			continue
		}
		if ($registered -and $line -match '^\s*L\[') {
			Add-Failure "$($localeFile.Name):$lineNumber zapisuje do L po SetTable(L)."
		}
	}

	if (-not $registered) {
		Add-Failure "$($localeFile.Name) nie rejestruje tabeli przez SetTable(L)."
	}
}

# On WoW 3.3.5 pooled frames may fire OnHide after FRAME_SHOWN. Search callbacks
# must navigate from the active input element, not from lifecycle-cleared private.frame.
$groupsPath = Join-Path $projectRoot "TradeSkillMaster\Core\UI\MainUI\Groups.lua"
$groupsLines = Get-Content -LiteralPath $groupsPath
$informationSearchBody = Get-LuaFunctionBody -Lines $groupsLines -FunctionName "InformationSearchOnValueChanged"
Test-SearchHandlerLifecycle `
	-Body $informationSearchBody `
	-FunctionName "InformationSearchOnValueChanged" `
	-TransitionPattern 'private\.BaseSearchOnValueChanged\(input\)'

$baseSearchBody = Get-LuaFunctionBody -Lines $groupsLines -FunctionName "BaseSearchOnValueChanged"
Test-SearchHandlerLifecycle `
	-Body $baseSearchBody `
	-FunctionName "BaseSearchOnValueChanged" `
	-TransitionPattern 'baseFrame:GetElement\("content\.groups\.view"\):SetPath\("search",\s*true\)'

# Unscanned items still need a safe non-nil default for the two market sources
# used by the stock auctioning operations.
$tsmRootSource = Get-Content -LiteralPath (Join-Path $projectRoot "TradeSkillMaster\TradeSkillMaster.lua") -Raw
if ($tsmRootSource -notmatch 'if not value and \(key == "marketValue" or key == "regionMarketValue"\) then' -or
	$tsmRootSource -notmatch 'value = vendorSell \* 2') {
	Add-Failure "DBMarket/DBRegionMarketAvg nie zachowują fallbacku vendorSell * 2 dla przedmiotów bez danych aukcyjnych."
}

# Cross-addon error capture is diagnostic behavior and must remain opt-in via
# /tsm debug on; otherwise unrelated addon failures are shown as TSM errors.
$bootstrapSource = Get-Content -LiteralPath (Join-Path $projectRoot "TradeSkillMaster\Compat\WrathBootstrap.lua") -Raw
if ($bootstrapSource -notmatch '_G\.TSM_GLOBAL_DEBUG = false' -or $bootstrapSource -match '_G\.TSM_GLOBAL_DEBUG = true') {
	Add-Failure "TSM_GLOBAL_DEBUG nie jest domyślnie wyłączony."
}

# Error UI strings are shared by every locale, so the default labels must remain
# language-neutral rather than being hardcoded for one client locale.
$errorFrameSource = Get-Content -LiteralPath (Join-Path $projectRoot "TradeSkillMaster\LibTSMUI\Source\Debug\ErrorFrame.lua") -Raw
foreach ($expectedText in @('TSM Error Window', 'Show Full Error', 'Select All \(Copy\)', 'TradeSkillMaster encountered an error')) {
	if ($errorFrameSource -notmatch $expectedText) {
		Add-Failure "ErrorFrame nie zawiera neutralnej etykiety: $expectedText."
	}
}

$slashCommandsSource = Get-Content -LiteralPath (Join-Path $projectRoot "TradeSkillMaster\LibTSMApp\Source\Service\SlashCommands.lua") -Raw
foreach ($expectedText in @('Debug mode: %s', 'Available commands: /tsm debug \[on\|off\|error\]')) {
	if ($slashCommandsSource -notmatch $expectedText) {
		Add-Failure "SlashCommands nie zawiera neutralnej etykiety: $expectedText."
	}
}

# A duplicated helper silently overrides its first definition and can diverge
# during later maintenance.
$wrapperSource = Get-Content -LiteralPath (Join-Path $projectRoot "TradeSkillMaster\LibTSMWoW\Source\API\AuctionHouseWrapper.lua") -Raw
$checkAllIdleCount = [regex]::Matches($wrapperSource, 'function private\.CheckAllIdle\(\)').Count
if ($checkAllIdleCount -ne 1) {
	Add-Failure "private.CheckAllIdle() powinno mieć dokładnie jedną definicję (otrzymano: $checkAllIdleCount)."
}

if ($failures.Count -gt 0) {
	Write-Host "FAIL: regresje backportu:" -ForegroundColor Red
	foreach ($failure in $failures) {
		Write-Host " - $failure" -ForegroundColor Red
	}
	exit 1
}

Write-Host "PASS: kontrakty locale, Groups, cen awaryjnych, izolacji debug, ErrorFrame i wrappera AH są zachowane."

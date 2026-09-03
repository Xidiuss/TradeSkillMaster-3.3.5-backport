$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$projectRoot = Split-Path -Parent $PSScriptRoot
$failures = New-Object System.Collections.Generic.List[string]

function Add-Failure {
	param([string] $Message)
	$script:failures.Add($Message)
}

function Convert-LuaPatternToDotNet {
	param([string] $Pattern)

	# This is the exact Lua-pattern subset used by Theme.RefreshItemIconLinkInText().
	return $Pattern.Replace("|", "\|").Replace(".-", ".*?").Replace("%d", "[0-9]")
}

function Invoke-RefreshPattern {
	param(
		[string] $Text,
		[string[]] $Patterns
	)

	foreach ($pattern in $Patterns) {
		$match = [regex]::Match($Text, (Convert-LuaPatternToDotNet -Pattern $pattern))
		if ($match.Success) {
			# Lua assigns only the first two strmatch captures to path and rest.
			return [pscustomobject]@{
				Matched = $true
				Path = $match.Groups[1].Value
				Rest = $match.Groups[2].Value
			}
		}
	}

	return [pscustomobject]@{
		Matched = $false
		Path = $null
		Rest = $Text
	}
}

# The Base Group search query returns three fields positionally to ItemList.
# Recreate one WotLK cache row: the raw numeric cache contains the -1 sentinel,
# while ItemInfo.GetTexture() resolves the real 3.3.5 string texture path.
$groupsPath = Join-Path $projectRoot "TradeSkillMaster\Core\UI\MainUI\Groups.lua"
$groupsText = Get-Content -LiteralPath $groupsPath -Raw
$updateMatch = [regex]::Match(
	$groupsText,
	'(?s)function private\.UpdateBaseItemInfoQuery\(\)(.*?)\r?\nend\r?\n\r?\nfunction private\.BaseSearchOnValueChanged'
)
if (-not $updateMatch.Success) {
	Add-Failure "Nie znaleziono pełnej funkcji private.UpdateBaseItemInfoQuery()."
} else {
	$updateBody = $updateMatch.Groups[1].Value
	$selectMatch = [regex]::Match(
		$updateBody,
		':Select\("([^\"]+)",\s*"([^\"]+)",\s*"([^\"]+)"\)'
	)
	$textureFieldMatch = [regex]::Match(
		$updateBody,
		':VirtualField\("([^\"]+)",\s*textureType,\s*ItemInfo\.GetTexture,\s*"([^\"]+)",\s*unknownTexture\)'
	)
	$ungroupedFieldMatch = [regex]::Match(
		$updateBody,
		':VirtualSmartMapField\("ungroupedItemString",\s*private\.ungroupedItemStringSmartMap,\s*"itemString"\)'
	)

	$row = @{
		itemString = "i:36909"
		ungroupedItemString = "i:36909"
		texture = -1
		coloredItemName = "Cobalt Ore"
	}
	$resolvedTexture = "Interface\Icons\INV_Ore_Cobalt"

	if (-not $textureFieldMatch.Success) {
		Add-Failure "Base Group nie definiuje pola tekstury rozwiązywanego przez ItemInfo.GetTexture()."
	} elseif ($textureFieldMatch.Groups[1].Value -ne "resolvedTexture") {
		Add-Failure "Pole tekstury Base Group musi używać bezkolizyjnego aliasu resolvedTexture."
	} elseif ($textureFieldMatch.Groups[2].Value -ne "ungroupedItemString") {
		Add-Failure "Pole tekstury Base Group nie zależy od ungroupedItemString."
	} else {
		$row[$textureFieldMatch.Groups[1].Value] = $resolvedTexture
	}

	if (-not $ungroupedFieldMatch.Success) {
		Add-Failure "Base Group nie definiuje ungroupedItemString przed rozwiązaniem tekstury."
	} elseif ($textureFieldMatch.Success -and $ungroupedFieldMatch.Index -gt $textureFieldMatch.Index) {
		Add-Failure "Base Group tworzy resolvedTexture przed zależnym polem ungroupedItemString."
	}

	if (-not $selectMatch.Success) {
		Add-Failure "Base Group nie wybiera trzech pól wymaganych przez ItemList."
	} else {
		$selectedIconField = $selectMatch.Groups[2].Value
		if (-not $row.ContainsKey($selectedIconField)) {
			Add-Failure "Drugie pole query Base Group nie istnieje w symulowanym wierszu."
		} elseif ($row[$selectedIconField] -ne $resolvedTexture) {
			Add-Failure "Base Group przekazuje do ItemList sentinel zamiast rozwiązanej ścieżki tekstury."
		}
	}
}

# Lua 5.1 resolves this local lexically, so the helper must be declared first.
$helperIndex = $groupsText.IndexOf("local function GetTextureFieldTypeAndDefault()")
$updateIndex = $groupsText.IndexOf("function private.UpdateBaseItemInfoQuery()")
if ($helperIndex -lt 0 -or $updateIndex -lt 0 -or $helperIndex -gt $updateIndex) {
	Add-Failure "Helper tekstury nie jest widoczny leksykalnie przed UpdateBaseItemInfoQuery()."
}

# Execute the actual Lua patterns from Theme against representative item-cell text.
# The expected names are hand-derived literals; assigning a size capture to "rest"
# recreates the reported visible values 12/16.
$themePath = Join-Path $projectRoot "TradeSkillMaster\LibTSMService\Source\UI\Theme.lua"
$themeText = Get-Content -LiteralPath $themePath -Raw
$refreshMatch = [regex]::Match(
	$themeText,
	'(?s)function Theme\.RefreshItemIconLinkInText\(text\)(.*?)\r?\nend\r?\n\r?\n---Gets display names'
)
if (-not $refreshMatch.Success) {
	Add-Failure "Nie znaleziono pełnej funkcji Theme.RefreshItemIconLinkInText()."
} else {
	$patternMatches = [regex]::Matches($refreshMatch.Groups[1].Value, 'strmatch\(text,\s*"([^\"]+)"\)')
	$patterns = @($patternMatches | ForEach-Object { $_.Groups[1].Value })
	if ($patterns.Count -ne 2) {
		Add-Failure "Theme.RefreshItemIconLinkInText() nie zawiera dokładnie dwóch obsługiwanych wariantów tagu."
	} else {
		$twoSizeResult = Invoke-RefreshPattern `
			-Text '|TInterface\Icons\INV_Ore_Cobalt:12:12|t Cobalt Ore' `
			-Patterns $patterns
		if (-not $twoSizeResult.Matched -or $twoSizeResult.Rest -ne " Cobalt Ore") {
			Add-Failure "Theme zwraca '$($twoSizeResult.Rest)' zamiast nazwy Cobalt Ore po tagu height:width."
		}

		$oneSizeResult = Invoke-RefreshPattern `
			-Text '|TInterface\Icons\INV_Ore_Saronite:16|t Saronite Ore' `
			-Patterns $patterns
		if (-not $oneSizeResult.Matched -or $oneSizeResult.Rest -ne " Saronite Ore") {
			Add-Failure "Theme zwraca '$($oneSizeResult.Rest)' zamiast nazwy Saronite Ore po tagu height."
		}

		$plainText = "Cobalt Ore"
		$plainResult = Invoke-RefreshPattern -Text $plainText -Patterns $patterns
		if ($plainResult.Matched -or $plainResult.Rest -ne $plainText) {
			Add-Failure "Theme zmienia tekst, który nie zaczyna się od tagu ikony."
		}
	}
}

if ($failures.Count -gt 0) {
	Write-Host "FAIL: regresje wyświetlania przedmiotów:" -ForegroundColor Red
	foreach ($failure in $failures) {
		Write-Host " - $failure" -ForegroundColor Red
	}
	exit 1
}

Write-Host "PASS: Base Group przekazuje rozwiązaną teksturę, a Theme zachowuje nazwy przedmiotów."

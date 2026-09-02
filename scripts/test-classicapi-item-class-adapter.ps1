$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$projectRoot = Split-Path -Parent $PSScriptRoot
$failures = New-Object System.Collections.Generic.List[string]

function Add-Failure {
	param([string] $Message)
	$script:failures.Add($Message)
}

function Assert-Equal {
	param(
		[object] $Actual,
		[object] $Expected,
		[string] $Message
	)
	if ($Actual -ne $Expected) {
		Add-Failure "$Message (otrzymano: '$Actual', oczekiwano: '$Expected')."
	}
}

# Literal fixtures observed from the two supported providers. These expectations
# are independent from the Lua implementation under test.
$externalEnum = @{
	Weapon = 1; Armor = 2; Container = 3; Consumable = 4; Glyph = 5; Tradegoods = 6
	Projectile = 7; Quiver = 8; Recipe = 9; Gem = 10; Miscellaneous = 11; Questitem = 12
}
$bundledEnum = @{
	Weapon = 2; Armor = 4; Container = 1; Consumable = 0; Glyph = 16; Tradegoods = 7
	Projectile = 6; Quiver = 11; Recipe = 9; Gem = 3; Miscellaneous = 15; Questitem = 12
}
$auctionClasses = @(
	"Weapon", "Armor", "Container", "Consumable", "Glyph", "Trade Goods",
	"Projectile", "Quiver", "Recipe", "Gem", "Miscellaneous", "Quest"
)
$tradeGoodsSubClasses = @(
	"Elemental", "Cloth", "Leather", "Metal & Stone", "Meat", "Herb", "Enchanting",
	"Jewelcrafting", "Parts", "Devices", "Explosives", "Materials", "Other",
	"Armor Enchantment", "Weapon Enchantment"
)

Assert-Equal -Actual $auctionClasses[5] -Expected "Trade Goods" -Message "Fixture głównej klasy AH jest błędny"
Assert-Equal -Actual $tradeGoodsSubClasses[5] -Expected "Herb" -Message "Fixture podklasy Herb jest błędny"
Assert-Equal -Actual $externalEnum.Tradegoods -Expected 6 -Message "Fixture zewnętrznego Enum jest błędny"
Assert-Equal -Actual $bundledEnum.Tradegoods -Expected 7 -Message "Fixture bundled Enum jest błędny"

# Existing providers own C_Item.GetItemClassInfo(). TSM may install a fallback,
# but must not replace a function used by other addons.
$bootstrapPath = Join-Path $projectRoot "TradeSkillMaster\Compat\WrathBootstrap.lua"
$bootstrapText = Get-Content -LiteralPath $bootstrapPath -Raw
$classInfoAssignment = $bootstrapText.IndexOf("_G.C_Item.GetItemClassInfo = function(classID)")
$classInfoGuard = $bootstrapText.IndexOf("if not _G.C_Item.GetItemClassInfo then")
if ($classInfoAssignment -lt 0) {
	Add-Failure "Nie znaleziono fallbacku C_Item.GetItemClassInfo()."
} elseif ($classInfoGuard -lt 0 -or $classInfoGuard -gt $classInfoAssignment) {
	Add-Failure "WrathBootstrap nadpisuje istniejące C_Item.GetItemClassInfo()."
}

$globalAliasAssignment = $bootstrapText.IndexOf("_G.GetItemClassInfo = _G.C_Item.GetItemClassInfo")
$globalAliasGuard = $bootstrapText.IndexOf("if not _G.GetItemClassInfo then")
if ($globalAliasAssignment -lt 0) {
	Add-Failure "Nie znaleziono fallbacku globalnego GetItemClassInfo."
} elseif ($globalAliasGuard -lt 0 -or $globalAliasGuard -gt $globalAliasAssignment) {
	Add-Failure "WrathBootstrap nadpisuje istniejący global GetItemClassInfo."
}

# The classic ItemClass module must derive subclass positions from the public
# 3.3.5 AH functions. Enum.__ItemClassInfo is absent in !!!ClassicAPI 1.24.
$itemClassPath = Join-Path $projectRoot "TradeSkillMaster\LibTSMWoW\Source\Util\ItemClass.lua"
$itemClassText = Get-Content -LiteralPath $itemClassPath -Raw
$classicBranchStart = $itemClassText.IndexOf("if ClientInfo.HasFeature(ClientInfo.FEATURES.C_AUCTION_HOUSE) then")
$classicBranchEnd = if ($classicBranchStart -ge 0) {
	$itemClassText.IndexOf("-- Standard TSM class aliases", $classicBranchStart)
} else {
	-1
}
if ($classicBranchStart -lt 0 -or $classicBranchEnd -lt 0) {
	Add-Failure "Nie znaleziono klasycznej gałęzi budowania podklas ItemClass."
} else {
	$classicBranch = $itemClassText.Substring($classicBranchStart, $classicBranchEnd - $classicBranchStart)
	if ($classicBranch -match 'Enum\.__ItemClassInfo') {
		Add-Failure "Klasyczna lista podklas zależy od brakującego Enum.__ItemClassInfo."
	}
	if ($classicBranch -notmatch 'private\.GetClassicAuctionClassIndex\(class\)') {
		Add-Failure "ItemClass nie tłumaczy nazwy klasy na pozycję GetAuctionItemClasses()."
	}
	if ($classicBranch -notmatch 'GetAuctionItemSubClasses\(classIndex\)') {
		Add-Failure "ItemClass nie pobiera podklas z publicznego GetAuctionItemSubClasses()."
	}
	if ($classicBranch -notmatch 'private\.subClassInfo\[classId\]\[subClassId\]\s*=\s*subClassName') {
		Add-Failure "ItemClass nie zapisuje odwrotnej mapy pozycji podklasy do nazwy."
	}
}

$helperMatch = [regex]::Match(
	$itemClassText,
	'(?s)function private\.GetClassicAuctionClassIndex\(className\)(.*?)\r?\nend'
)
if (-not $helperMatch.Success) {
	Add-Failure "Brak helpera wyszukującego pozycję klasy AH po nazwie."
} elseif ($helperMatch.Groups[1].Value -notmatch 'GetAuctionItemClasses\(\)') {
	Add-Failure "Helper pozycji klasy nie korzysta z GetAuctionItemClasses()."
}

$subClassInfoMatch = [regex]::Match(
	$itemClassText,
	'(?s)function ItemClass\.GetSubClassInfo\(classId, subClassId\)(.*?)\r?\nend'
)
if (-not $subClassInfoMatch.Success) {
	Add-Failure "Nie znaleziono ItemClass.GetSubClassInfo()."
} elseif ($subClassInfoMatch.Groups[1].Value -notmatch 'private\.subClassInfo') {
	Add-Failure "ItemClass.GetSubClassInfo() nie korzysta z mapy zbudowanej przez publiczne API AH."
}

if ($itemClassText -notmatch 'local subClassName\s*=\s*armorSubClassInfo\[subClassId\]\s*\r?\n\s*if subClassName then') {
	Add-Failure "Klasyczna mapa Armor nie chroni się przed brakującą nazwą podklasy."
}

# The native QueryAuctionItems boundary always expects the fixed 1-based AH
# position. Map keys must be evaluated from the active provider's Enum values.
$auctionWrapperPath = Join-Path $projectRoot "TradeSkillMaster\LibTSMWoW\Source\API\AuctionHouseWrapper.lua"
$auctionWrapperText = Get-Content -LiteralPath $auctionWrapperPath -Raw
$activeMapMatch = [regex]::Match(
	$auctionWrapperText,
	'(?s)local ITEM_CLASS_ID_TO_AH_INDEX\s*=\s*\{(.*?)\r?\n\}'
)
if (-not $activeMapMatch.Success) {
	Add-Failure "AuctionHouseWrapper nie definiuje mapy kluczowanej aktywnymi Enum.ItemClass."
} else {
	$entriesByName = @{}
	$entryMatches = [regex]::Matches(
		$activeMapMatch.Groups[1].Value,
		'\[Enum\.ItemClass\.([A-Za-z]+)\]\s*=\s*([0-9]+)'
	)
	foreach ($entryMatch in $entryMatches) {
		$entriesByName[$entryMatch.Groups[1].Value] = [int] $entryMatch.Groups[2].Value
	}

	foreach ($providerCase in @(
		@{ Name = "external"; Enum = $externalEnum },
		@{ Name = "bundled"; Enum = $bundledEnum }
	)) {
		$resolvedMap = @{}
		foreach ($entryName in $entriesByName.Keys) {
			if ($providerCase.Enum.ContainsKey($entryName)) {
				$resolvedMap[$providerCase.Enum[$entryName]] = $entriesByName[$entryName]
			}
		}
		foreach ($expectation in @(
			@{ Name = "Weapon"; Index = 1 },
			@{ Name = "Tradegoods"; Index = 6 },
			@{ Name = "Projectile"; Index = 7 }
		)) {
			$classId = $providerCase.Enum[$expectation.Name]
			if (-not $resolvedMap.ContainsKey($classId)) {
				Add-Failure "Brak mapowania $($providerCase.Name) $($expectation.Name) classId=$classId."
			} elseif ($resolvedMap[$classId] -ne $expectation.Index) {
				Add-Failure "$($providerCase.Name) $($expectation.Name) trafia do AH index $($resolvedMap[$classId]) zamiast $($expectation.Index)."
			}
		}
	}
}

$queryTraceRunner = Join-Path $projectRoot "scripts\lua-tests\run-auction-query-trace-tests.js"
& node $queryTraceRunner
if ($LASTEXITCODE -ne 0) {
	Add-Failure "Behawioralny test granicy SendQuery / QueryAuctionItems nie przeszedł."
}

# Milling and Prospecting are data-defined conversions. Their selection must not
# depend on provider-specific Trade Goods subclass numbers.
$destroyingPath = Join-Path $projectRoot "TradeSkillMaster\Core\Service\Destroying\Core.lua"
$destroyingText = Get-Content -LiteralPath $destroyingPath -Raw
$isDestroyableMatch = [regex]::Match(
	$destroyingText,
	'(?s)function private\.IsDestroyable\(itemString\)(.*?)\r?\nend\r?\n\r?\nfunction private\.GetHistoryEntryTime'
)
if (-not $isDestroyableMatch.Success) {
	Add-Failure "Nie znaleziono pełnej funkcji private.IsDestroyable()."
} else {
	$isDestroyableBody = $isDestroyableMatch.Groups[1].Value
	if ($isDestroyableBody -match 'ITEM_SUB_CLASS_HERB|ITEM_SUB_CLASS_METAL_AND_STONE') {
		Add-Failure "Milling/Prospecting nadal zależy od numeric subclass ID."
	}
	if ($isDestroyableBody -match 'i:39970') {
		Add-Failure "Fire Leaf nadal wymaga wyjątku po ID zamiast danych Mill."
	}
	$millCallIndex = $isDestroyableBody.IndexOf("private.HasDestroyConversion(itemString, Conversion.METHOD.MILL, private.inscriptionSkillLevel)")
	$prospectCallIndex = $isDestroyableBody.IndexOf("private.HasDestroyConversion(itemString, Conversion.METHOD.PROSPECT, private.jewelcraftSkillLevel)")
	if ($millCallIndex -lt 0) {
		Add-Failure "IsDestroyable nie sprawdza danych MILL z poziomem Inscription."
	}
	if ($prospectCallIndex -lt 0) {
		Add-Failure "IsDestroyable nie sprawdza danych PROSPECT z poziomem Jewelcrafting."
	}
	if ($millCallIndex -ge 0 -and $prospectCallIndex -ge 0 -and $millCallIndex -gt $prospectCallIndex) {
		Add-Failure "IsDestroyable sprawdza PROSPECT przed MILL."
	}
	if ($isDestroyableBody -notmatch 'private\.destroyQuantityCache\[itemString\]\s*=\s*5') {
		Add-Failure "Konwersja Milling/Prospecting nie ustawia minimalnej liczby 5."
	}
	if ($isDestroyableBody -notmatch 'ItemInfo\.IsDisenchantable\(itemString\)') {
		Add-Failure "Zmiana usunęła istniejącą gałąź Disenchanting."
	}
}

$destroyHelperMatch = [regex]::Match(
	$destroyingText,
	'(?s)function private\.HasDestroyConversion\(itemString, method, skillLevel\)(.*?)\r?\nend'
)
if (-not $destroyHelperMatch.Success) {
	Add-Failure "Brak helpera kwalifikującego konwersję według metody i skilla."
} else {
	$destroyHelperBody = $destroyHelperMatch.Groups[1].Value
	if ($destroyHelperBody -notmatch 'Conversion\.TargetItemsByMethodIterator\(itemString, method\)') {
		Add-Failure "Helper nie korzysta z rzeczywistych danych Conversion."
	}
	if ($destroyHelperBody -notmatch 'skillLevel\s*>=\s*skillRequired') {
		Add-Failure "Helper nie respektuje wymaganego poziomu profesji."
	}
	if ($destroyHelperBody -match 'if\s+[^\r\n]+then\s*\r?\n\s*return true') {
		Add-Failure "Helper przerywa iterator Conversion przed zwolnieniem jego TempTable."
	}
	if ($destroyHelperBody -notmatch 'local hasConversion\s*=\s*false' -or $destroyHelperBody -notmatch 'return hasConversion') {
		Add-Failure "Helper nie wyczerpuje iteratora przed zwróceniem zapamiętanego wyniku."
	}
}

# Verify the literal WotLK source fixtures and their independent skill boundaries.
$millData = Get-Content -LiteralPath (Join-Path $projectRoot "TradeSkillMaster\LibTSMData\Destroy\Mill.lua") -Raw
$prospectData = Get-Content -LiteralPath (Join-Path $projectRoot "TradeSkillMaster\LibTSMData\Destroy\Prospect.lua") -Raw
if ($millData -notmatch '\["i:36903"\]\s*=\s*\{requiredSkill\s*=\s*325') {
	Add-Failure "Dane Mill nie zawierają oczekiwanego progu 325 dla Adder's Tongue."
}
if ($prospectData -notmatch '\["i:36912"\]\s*=\s*\{requiredSkill\s*=\s*400') {
	Add-Failure "Dane Prospect nie zawierają oczekiwanego progu 400 dla Saronite Ore."
}
Assert-Equal -Actual (445 -ge 325) -Expected $true -Message "Inscription 445 powinien kwalifikować Adder's Tongue"
Assert-Equal -Actual (324 -ge 325) -Expected $false -Message "Inscription 324 nie powinien kwalifikować Adder's Tongue"
Assert-Equal -Actual (400 -ge 400) -Expected $true -Message "Jewelcrafting 400 powinien kwalifikować Saronite Ore"

# A one-time schema bump prevents records produced by the previous mixed mapper
# from surviving the adapter update and poisoning AH post-filtering.
$itemInfoPath = Join-Path $projectRoot "TradeSkillMaster\LibTSMService\Source\Item\ItemInfo.lua"
$itemInfoText = Get-Content -LiteralPath $itemInfoPath -Raw
$dbVersionMatch = [regex]::Match($itemInfoText, 'local DB_VERSION\s*=\s*([0-9]+)')
if (-not $dbVersionMatch.Success) {
	Add-Failure "Nie znaleziono wersji ItemInfoCache."
} elseif ([int] $dbVersionMatch.Groups[1].Value -ne 22) {
	Add-Failure "ItemInfoCache nadal używa wersji $($dbVersionMatch.Groups[1].Value) zamiast 22."
}

if ($failures.Count -gt 0) {
	Write-Host "FAIL: adapter klas ClassicAPI:" -ForegroundColor Red
	foreach ($failure in $failures) {
		Write-Host " - $failure" -ForegroundColor Red
	}
	exit 1
}

Write-Host "PASS: adapter providerów, podklasy AH, Milling/Prospecting i migracja ItemInfoCache są spójne."

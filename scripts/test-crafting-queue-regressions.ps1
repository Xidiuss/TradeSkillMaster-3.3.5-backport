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
		[string] $FunctionPattern
	)

	$startPattern = '^function\s+' + $FunctionPattern + '\('
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

	Add-Failure "Nie znaleziono pełnej funkcji $FunctionPattern()."
	return ""
}

# On 3.3.5 the craft spellId stored in craftStrings is a synthetic djb2 hash from
# the classic profession scanner, so GetSpellInfo() can never resolve it. The
# cast must be recognized by name against craftName (the same value
# SpellMatchesCraft compares on UNIT_SPELLCAST_SUCCEEDED). Without the name
# comparison CraftTimeoutMonitor sees the -1 sentinel ("crafting something
# else") 0.5 s into every craft and the queue never advances.
function Test-CraftCastMatching {
	param([string] $BranchText)

	$issues = New-Object System.Collections.Generic.List[string]
	$blockMatch = [regex]::Match(
		$BranchText,
		'(?s)local\s+spellId\s*=\s*nil(?:(?:\r?\n)?\s*--[^\r\n]*)*\s*\r?\n\s*if\s+(?<cond>[^\r\n]+)\s+then\s*\r?\n\s*spellId\s*=\s*private\.craftSpellId\s*\r?\n\s*else(?<else>.*?)\r?\n\s*end'
	)
	if (-not $blockMatch.Success) {
		$issues.Add("Gałąź 3.3.5 GetPlayerCastingInfo nie zawiera bloku rozstrzygania spellId.")
		return $issues
	}

	$cond = $blockMatch.Groups["cond"].Value
	if ($cond -notmatch 'private\.craftSpellId\s+and') {
		$issues.Add("Rozpoznanie castu nie jest strzeżone obecnością private.craftSpellId.")
	}
	if ($cond -notmatch 'private\.craftName\s*==\s*name') {
		$issues.Add("Rozpoznanie castu nie porównuje nazwy z private.craftName (hash nie jest prawdziwym spell ID).")
	}
	if ($cond -notmatch 'GetSpellInfo\(private\.craftSpellId\)\s*==\s*name') {
		$issues.Add("Rozpoznanie castu utraciło fallback GetSpellInfo(craftSpellId).")
	}
	if ($cond -notmatch 'private\.craftName\s*==\s*name\s+or\s+' -and $cond -notmatch '\s+or\s+private\.craftName\s*==\s*name') {
		$issues.Add("Porównanie craftName nie jest alternatywą względem fallbacku spellId.")
	}
	if ($blockMatch.Groups["else"].Value -notmatch 'spellId\s*=\s*-1') {
		$issues.Add("Zniknął sentinel -1 dla obcego castu.")
	}

	return $issues
}

# BAG_UPDATE_DELAYED was added in 5.0.4 and never fires on the 3.3.5 client, so
# the bag DB would stay frozen at login unless the timer emulation is used.
function Test-BagUpdateDelayedEmulation {
	param(
		[string] $Condition,
		[string] $ThenBody,
		[string] $ElseBody
	)

	$issues = New-Object System.Collections.Generic.List[string]
	if ($Condition -notmatch 'LibTSMService\.IsPandaClassic\(\)') {
		$issues.Add("Emulacja przestała obejmować klienta Panda/Cata.")
	}
	if ($Condition -notmatch 'LibTSMService\.IsRetail\(\)') {
		$issues.Add("Emulacja przestała obejmować klienta Retail.")
	}
	if ($Condition -notmatch 'LibTSMService\.IsWrathClassic\(\)') {
		$issues.Add("Klient Wrath (3.3.5) nie używa emulacji BAG_UPDATE_DELAYED - baza toreb zamrożona po logowaniu.")
	}
	if ($ThenBody -notmatch 'bagUpdateDelayedTimer' -or $ThenBody -notmatch 'RunForFrames\(0\)') {
		$issues.Add("Gałąź emulacji nie planuje BagUpdateDelayedHandler po BAG_UPDATE.")
	}
	if ($ElseBody -notmatch 'BAG_UPDATE_DELAYED') {
		$issues.Add("Gałąź else utraciła rejestrację BAG_UPDATE_DELAYED dla klientów z tym zdarzeniem.")
	}

	return $issues
}

function Test-LoginFullBagScan {
	param([string] $Body)

	$issues = New-Object System.Collections.Generic.List[string]
	$loopMatch = [regex]::Match(
		$Body,
		'(?s)for\s+bag\s*=\s*Container\.GetBackpackContainer\(\),\s*Container\.GetNumBags\(\)\s+do(?<loop>.*?)\r?\n\s*end'
	)
	if (-not $loopMatch.Success) {
		$issues.Add("HandleLogin nie iteruje po wszystkich torbach (backpack + worn bags).")
	} elseif ($loopMatch.Groups["loop"].Value -notmatch 'private\.BagUpdateHandler\(nil,\s*bag\)') {
		$issues.Add("Pętla logowania nie oznacza toreb jako pending przez BagUpdateHandler(nil, bag).")
	}
	if ($Body -match 'private\.BagUpdateHandler\(nil,\s*0\)') {
		$issues.Add("HandleLogin nadal skanuje tylko backpack (bag 0).")
	}
	if ($Body -notmatch 'private\.BagUpdateDelayedHandler\(\)') {
		$issues.Add("HandleLogin nie wywołuje BagUpdateDelayedHandler po oznaczeniu toreb.")
	}

	return $issues
}

function Test-RestockRescan {
	param([string] $Body, [string] $FileText)

	$issues = New-Object System.Collections.Generic.List[string]
	$rescanMatch = [regex]::Match($Body, 'BagTracking\.RescanAllBags\(\)')
	$pauseMatch = [regex]::Match($Body, 'private\.db:SetQueryUpdatesPaused\(true\)')
	if (-not $rescanMatch.Success) {
		$issues.Add("Queue.RestockGroups nie wykonuje BagTracking.RescanAllBags() przed obliczeniami.")
	} elseif ($pauseMatch.Success -and $rescanMatch.Index -gt $pauseMatch.Index) {
		$issues.Add("RescanAllBags wykonywany jest dopiero po wstrzymaniu update'ów query kolejki.")
	}
	if ($FileText -notmatch 'local\s+BagTracking\s*=\s*TSM\.LibTSMService:Include\("Inventory\.BagTracking"\)') {
		$issues.Add("Queue.lua nie dołącza modułu Inventory.BagTracking.")
	}

	return $issues
}

# NumInventory always includes the current player's own inventory, so the
# ignore-characters subtraction must never apply to the player's own character;
# otherwise every owned item cancels out and restock re-queues everything.
function Test-RestockIgnoreSelfGuard {
	param([string] $RestockItemBody, [string] $QueueFileText, [string] $SettingsUIFileText)

	$issues = New-Object System.Collections.Generic.List[string]
	if ($RestockItemBody -notmatch 'if\s+ignored\s+and\s+not\s+SessionInfo\.IsPlayer\(player\)\s+then') {
		$issues.Add("RestockItem odejmuje ignorowane postaci bez wykluczenia bieżącej postaci (własny inwentarz znika z kalkulacji).")
	}
	if ($QueueFileText -notmatch 'local\s+SessionInfo\s*=\s*TSM\.LibTSMWoW:Include\("Util\.SessionInfo"\)') {
		$issues.Add("Queue.lua nie dołącza Util.SessionInfo dla guardu IsPlayer.")
	}
	if ($SettingsUIFileText -notmatch 'if\s+not\s+SessionInfo\.IsPlayer\(character\)\s+then\s*\r?\n\s*tinsert\(private\.altCharacters,\s*character\)') {
		$issues.Add("Lista 'Ignore Characters' oferuje bieżącą postać do wyboru.")
	}

	return $issues
}

function Test-OwnedAuctionScan {
	param([string] $Body)

	$issues = New-Object System.Collections.Generic.List[string]
	$postponeMatch = [regex]::Match(
		$Body,
		'(?s)IsDefaultOwnedAuctionTabVisible\(\)\s+then\s*\r?\n\s*--[^\r\n]*\r?\n\s*private\.scanTimer:RunForFrames\(2\)\s*\r?\n\s*return'
	)
	if ($postponeMatch.Success) {
		$issues.Add("Skan własnych aukcji jest wstrzymiwany przy widocznej zakładce Auctions i przerywany przy zamknięciu AH.")
	}
	$gateMatch = [regex]::Match($Body, 'not\s+DefaultUI\.IsDefaultOwnedAuctionTabVisible\(\)')
	$sortMatch = [regex]::Match($Body, 'AreOwnedSortedByOwnerDuration\(\)')
	if (-not $gateMatch.Success) {
		$issues.Add("Re-sort listy owner nie jest pomijany przy widocznej zakładce Auctions.")
	} elseif ($sortMatch.Success -and $gateMatch.Index -gt $sortMatch.Index) {
		$issues.Add("Warunek widocznej zakładki Auctions musi poprzedzać sprawdzenie sortowania owner.")
	}
	if ($Body -notmatch 'private\.ScanOwnedAuctions\(\)') {
		$issues.Add("ScanTimerHandler nie wywołuje już skanowania własnych aukcji.")
	}

	return $issues
}

# On the 3.3.5 client PLAYER_INTERACTION_MANAGER_FRAME_* doesn't exist and the
# external !!!ClassicAPI never rebroadcasts its synthetic copy to other addons'
# frames, so UI visibility (AH/mail/bank/guild bank/merchant) would stay false
# forever - silently disabling the owned-auctions scan. Classic clients must map
# the real show/close events onto the visibility state instead.
function Test-ClassicVisibilityEvents {
	param([string] $Body)

	$issues = New-Object System.Collections.Generic.List[string]
	if ($Body -notmatch 'IsVanillaClassic\(\)\s+or\s+ClientInfo\.IsBCClassic\(\)\s+or\s+ClientInfo\.IsWrathClassic\(\)') {
		$issues.Add("Klasyczne zdarzenia widoczności nie są ograniczone do klientów Vanilla/BC/Wrath.")
	}
	$pairs = @(
		@("AUCTION_HOUSE_SHOW", "FRAMES\.AUCTION_HOUSE", "true"),
		@("AUCTION_HOUSE_CLOSED", "FRAMES\.AUCTION_HOUSE", "false"),
		@("MAIL_SHOW", "FRAMES\.MAIL", "true"),
		@("BANKFRAME_OPENED", "FRAMES\.BANK", "true"),
		@("GUILDBANKFRAME_OPENED", "FRAMES\.GUILDBANK", "true")
	)
	foreach ($pair in $pairs) {
		$event, $frame, $visible = $pair
		if ($Body -notmatch ('RegisterVisibilityEvent\("' + $event + '",\s*' + $frame + ',\s*' + $visible + '\)')) {
			$issues.Add("DefaultUI nie mapuje $event na widoczność $frame=$visible.")
		}
	}

	return $issues
}

function Test-RescanFlushesQuantityCallbacks {
	param([string] $Body)

	$issues = New-Object System.Collections.Generic.List[string]
	$flushMatch = [regex]::Match($Body, 'private\.DelayedBagTrackingQuantityCallback\(\)')
	$unpauseMatch = [regex]::Match($Body, 'SetQueryUpdatesPaused\(false\)')
	if (-not $flushMatch.Success) {
		$issues.Add("RescanAllBags nie przepłukuje callbacków ilości - NumInventory czyta sterowany cache.")
	} elseif ($unpauseMatch.Success -and $flushMatch.Index -lt $unpauseMatch.Index) {
		$issues.Add("Przepłukanie callbacków ilości musi następować po wznowieniu update'ów query.")
	}

	return $issues
}

function Test-CraftingUIOpenRescan {
	param([string] $Body)

	$issues = New-Object System.Collections.Generic.List[string]
	if ($Body -notmatch 'BagTracking\.RescanAllBags\(\)') {
		$issues.Add("Otwarcie okna profesji nie odświeża danych toreb (craftability nadal na zamrożonych danych).")
	}
	if ($Body -notmatch 'not\s+ClientInfo\.IsRetail\(\)') {
		$issues.Add("Rescan przy otwarciu okna profesji nie jest ograniczony do klientów klasycznych.")
	}

	return $issues
}

# On 3.3.5 the owner auction list starts empty each AH session and is only
# populated once the client receives the server's data. A scan running earlier
# wipes the persisted auction quantities with an empty result (data loss on
# every AH open/close cycle where the list never loads), so OwnedFullyLoaded()
# must gate on actual list availability.
function Test-OwnedListLoadGate {
	param([string] $FileText)

	$issues = New-Object System.Collections.Generic.List[string]
	if ($FileText -notmatch 'Event\.Register\("AUCTION_HOUSE_SHOW",\s*function\(\)\s*private\.ownedListLoaded\s*=\s*false\s*end\)') {
		$issues.Add("OwnedFullyLoaded: flaga ownedListLoaded nie jest resetowana przy otwarciu AH.")
	}
	if ($FileText -notmatch 'Event\.Register\("AUCTION_OWNED_LIST_UPDATE",\s*function\(\)\s*private\.ownedListLoaded\s*=\s*true\s*end\)') {
		$issues.Add("OwnedFullyLoaded: flaga ownedListLoaded nie jest ustawiana po otrzymaniu listy owner.")
	}
	$fnMatch = [regex]::Match($FileText, '(?s)function AuctionHouse\.OwnedFullyLoaded\(\)(?<body>.*?)\r?\nend')
	if (-not $fnMatch.Success) {
		$issues.Add("Nie znaleziono funkcji AuctionHouse.OwnedFullyLoaded().")
	} elseif ($fnMatch.Groups["body"].Value -notmatch 'private\.ownedListLoaded\s+or\s+AuctionHouse\.GetNumOwned\(\)\s*>\s*0') {
		$issues.Add("OwnedFullyLoaded na 3.3.5 nie bramkuje skanu dostępnością listy owner (skan z pustą listą wyzerowuje dane).")
	}

	return $issues
}

# The per-item cost of classic post/cancel scans is dominated by retry cadences
# (each pending recheck rounds the wait up to a multiple of the retry delay) and
# by the owner-name wait. Keep the cadences low and the seller wait time-based.
function Test-ScanPacing {
	param([string] $ScannerText, [string] $CoreText)

	$issues = New-Object System.Collections.Generic.List[string]
	if ($ScannerText -notmatch 'BROWSE_MISSING_INFO_RETRY_DELAY\s*=\s*0\.15') {
		$issues.Add("Cadencja ponownego sprawdzania pending wierszy nie jest 0.15s (wolne skany post/cancel).")
	}
	if ($ScannerText -notmatch 'BROWSE_EMPTY_RETRY_DELAY\s*=\s*0\.1') {
		$issues.Add("Retry pustej strony nie jest 0.1s (przedmioty bez aukcji tracą do 3s).")
	}
	if ($ScannerText -match 'private\.query\._str\s*~=\s*""\s+and\s+private\.browseEmptyRetryCount') {
		$issues.Add("Puste zapytanie CATEGORY omija retry przejściowo pustej odpowiedzi.")
	}
	if ($ScannerText -notmatch '(?s)numAuctions\s*==\s*0.*?GetScanPlanKind\(\)\s*==\s*"CATEGORY".*?GetPage\(\)\s*==\s*0.*?_SetBrowseEndReason\("INCOMPLETE"\)') {
		$issues.Add("Niepotwierdzona pusta pierwsza strona CATEGORY nie uruchamia fallbacków przez INCOMPLETE.")
	}
	if ($ScannerText -notmatch 'GetTime\(\)\s*-\s*private\.sellerWaitStart\s*<\s*SELLER_WAIT_MAX_TIME') {
		$issues.Add("Oczekiwanie na ownerów nie jest ograniczone czasowo (licznościowe czekanie zaokrągla do 0.5s).")
	}
	if ($ScannerText -notmatch 'TSM_SCAN_TRACE') {
		$issues.Add("Brak instrumentacji czasowej skanu (TSM_SCAN_TRACE).")
	}
	if ($CoreText -notmatch '"scantrace"') {
		$issues.Add("Brak podkomendy scantrace w /tsmcraftdebug.")
	}

	return $issues
}

# The server rate-limits AH searches (~2s between responses), so per-item name
# queries dominate post/cancel scan time. Narrow-class items (glyphs) must be
# batched into a single paged class query instead.
function Test-ClassBatchQuery {
	param([string] $QueryUtilText)

	$issues = New-Object System.Collections.Generic.List[string]
	if ($QueryUtilText -notmatch 'CLASS_BATCH_MIN_ITEMS\s*=\s*13') {
		$issues.Add("Próg CATEGORY nie wynosi dokładnie 13 targetów.")
	}
	if ($QueryUtilText -notmatch '\[16\]\s*=\s*true' -or $QueryUtilText -notmatch '\[5\]\s*=\s*true') {
		$issues.Add("Allowlista klas nie obejmuje Glyph (canonical 16 / positional 5).")
	}
	if ($QueryUtilText -notmatch 'SetStr\("",\s*false\)\s*\r?\n\s*:SetClass\(classId,\s*nil\)') {
		$issues.Add("Brak konstrukcji CATEGORY (str pusty + właściwa klasa).")
	}
	if ($QueryUtilText -notmatch 'SetScanPlanKind\("CATEGORY"\)' -or $QueryUtilText -notmatch 'SetScanPlanKind\("NARROW"\)' -or $QueryUtilText -notmatch 'SetScanPlanKind\("EXACT"\)') {
		$issues.Add("Plan nie oznacza wszystkich rodzajów CATEGORY/NARROW/EXACT.")
	}
	if ($QueryUtilText -notmatch 'SetFallbackParent') {
		$issues.Add("Plan nie łączy fallbacków z rodzicami.")
	}
	if ($QueryUtilText -notmatch 'fallbackEst\s*<\s*remainingPageEst') {
		$issues.Add("Przełączenie kosztowe nie używa ścisłego < (remis musi kontynuować query).")
	}
	if ($QueryUtilText -notmatch 'for\s+_,\s*itemString\s+in\s+ipairs\(nameQueryItems\)\s+do') {
		$issues.Add("Ścieżka kwerend nazwowych nie działa na pozostałych itemach (nameQueryItems).")
	}

	return $issues
}

function Test-ScanPlannerConsumerGuard {
	param([string] $QueryText, [string] $ScanManagerText, [string] $PostScanText, [string] $CancelScanText, [string] $ScannerText)

	$issues = New-Object System.Collections.Generic.List[string]
	foreach ($text in @($PostScanText, $CancelScanText)) {
		if ($text -notmatch 'GetScanPlanKind\(\)' -or $text -notmatch '(?:if|and)\s+not\s+scanPlanKind' -or $text -match 'scanPlanKind\s*==\s*"EXACT"') {
			$issues.Add("PostScan/CancelScan nie zachowuje pełnego browse dla wszystkich query plannera.")
			break
		}
	}
	if ($QueryText -notmatch 'function AuctionQuery:HasCompletedFullBrowse\(\)' -or $QueryText -notmatch 'function AuctionQuery:GetEndReason\(\)') {
		$issues.Add("Query nie udostępnia publicznego kontraktu pełnego końca i reason.")
	}
	if ($ScanManagerText -notmatch 'HasCompletedFullBrowse\(\)' -or $ScanManagerText -notmatch 'GetEndReason\(\)') {
		$issues.Add("ScanManager nie interpretuje publicznego kontraktu końca Query.")
	}
	if ($ScannerText -notmatch 'HasEndedEarly\(\)' -or $ScannerText -notmatch 'GetEndReason\(\)') {
		$issues.Add("Trace Scannera nadal czyta prywatny lub domyślny stan końca.")
	}
	return $issues
}

# Price-ascending pages make the first subrow seen per item its cheapest auction,
# which is what allows the auctioning scans to stop paging early. The ordering is
# self-verified while pages arrive; a violation revokes IsPriceSorted() so the
# scans fall back to full pagination (correct prices) instead of posting above
# the real cheapest auction.
function Test-PriceSortEarlyStop {
	param([string] $QueryText, [string] $PostScanText, [string] $CancelScanText, [string] $ScanScannerText)

	$issues = New-Object System.Collections.Generic.List[string]
	if ($QueryText -notmatch 'function AuctionQuery:IsPriceSorted\(\)') {
		$issues.Add("Brak gettera IsPriceSorted() na AuctionQuery.")
	}
	if ($QueryText -notmatch 'not\s+self\._priceSortBroken') {
		$issues.Add("IsPriceSorted() nie uwzględnia flagi złamanego sortowania cenowego.")
	}
	if ($QueryText -notmatch 'function AuctionQuery:_RecordBrowseUnitPrice') {
		$issues.Add("Brak metody weryfikacji kolejności cen (_RecordBrowseUnitPrice).")
	}
	if ($ScanScannerText -notmatch '_RecordBrowseUnitPrice\(unitBuyout(,\s*buyout)?\)' -and $ScanScannerText -notmatch '_RecordBrowseUnitPrice\(buyout\s*/\s*stackSize\)') {
		$issues.Add("Scanner nie nagrywa cen jednostkowych wierszy (brak weryfikacji sortowania).")
	}
	if ($QueryText -notmatch 'function AuctionQuery:IsBuyoutOrdered\(\)') {
		$issues.Add("Brak niezależnej weryfikacji kolejnosci BUYOUT (IsBuyoutOrdered).")
	}
	if ($QueryText -notmatch '(?s)function AuctionQuery:Browse\(\).*?self\._priceSortBroken\s*=\s*false.*?self\._priceSortMaxUnitSeen\s*=\s*nil.*?self\._buyoutOrderBroken\s*=\s*false.*?self\._buyoutSortMaxSeen\s*=\s*nil') {
		$issues.Add("Nowy Browse nie resetuje dowodów sortowania z poprzedniej próby query.")
	}
	if ($PostScanText -notmatch 'numBuyouts\s*<=\s*1\s+and\s+not\s+query:IsPriceSorted\(\)') {
		$issues.Add("PostScan nie rozluźnia warunku stopu dla kwerend sortowanych cenowo.")
	}
	if ($CancelScanText -notmatch 'SetIsBrowseDoneFunction\(private\.QueryIsBrowseDoneFunction\)') {
		$issues.Add("CancelScan nie ma funkcji wczesnego stopu (stronicuje całą kategorię).")
	}
	if ($CancelScanText -notmatch 'query:IsPriceSorted\(\)') {
		$issues.Add("Funkcja stopu CancelScan nie jest ograniczona do kwerend sortowanych cenowo.")
	}

	return $issues
}

# --- Real source contracts ---

$professionUtilPath = Join-Path $projectRoot "TradeSkillMaster_Crafting\Service\ProfessionUtil.lua"
$professionUtilText = Get-Content -LiteralPath $professionUtilPath -Raw
$castingBranchMatch = [regex]::Match(
	$professionUtilText,
	'(?s)local\s+name,\s*_,\s*text,\s*texture,\s*startTimeMs,\s*endTimeMs,\s*isTradeSkill,\s*castId,\s*notInterruptible\s*=\s*UnitCastingInfo\("player"\)(?<branch>.*?)\r?\nfunction '
)
if (-not $castingBranchMatch.Success) {
	Add-Failure "Nie znaleziono gałęzi 3.3.5 w ProfessionUtil.GetPlayerCastingInfo()."
} else {
	foreach ($issue in (Test-CraftCastMatching -BranchText $castingBranchMatch.Groups["branch"].Value)) {
		Add-Failure $issue
	}
}

$bagTrackingPath = Join-Path $projectRoot "TradeSkillMaster\LibTSMService\Source\Inventory\BagTracking.lua"
$bagTrackingLines = Get-Content -LiteralPath $bagTrackingPath
$bagTrackingStart = Get-LuaFunctionBody -Lines $bagTrackingLines -FunctionPattern 'BagTracking\.Start'
$branchMatch = [regex]::Match(
	$bagTrackingStart,
	'(?s)if\s+(?<cond>LibTSMService\.[^\r\n]+)\s+then\s*\r?\n(?<then>.*?)\r?\n\s*else\s*\r?\n(?<else>.*?)\r?\n\s*end'
)
if (-not $branchMatch.Success) {
	Add-Failure "Nie znaleziono gałęzi emulacji BAG_UPDATE_DELAYED w BagTracking.Start()."
} else {
	foreach ($issue in (Test-BagUpdateDelayedEmulation `
			-Condition $branchMatch.Groups["cond"].Value `
			-ThenBody $branchMatch.Groups["then"].Value `
			-ElseBody $branchMatch.Groups["else"].Value)) {
		Add-Failure $issue
	}
}

$handleLoginBody = Get-LuaFunctionBody -Lines $bagTrackingLines -FunctionPattern 'private\.HandleLogin'
foreach ($issue in (Test-LoginFullBagScan -Body $handleLoginBody)) {
	Add-Failure $issue
}

$queuePath = Join-Path $projectRoot "TradeSkillMaster_Crafting\Service\Queue.lua"
$queueText = Get-Content -LiteralPath $queuePath -Raw
$restockBody = Get-LuaFunctionBody -Lines (Get-Content -LiteralPath $queuePath) -FunctionPattern 'Queue\.RestockGroups'
foreach ($issue in (Test-RestockRescan -Body $restockBody -FileText $queueText)) {
	Add-Failure $issue
}

$restockItemBody = Get-LuaFunctionBody -Lines (Get-Content -LiteralPath $queuePath) -FunctionPattern 'private\.RestockItem'
$settingsCraftingUIPath = Join-Path $projectRoot "TradeSkillMaster_Crafting\UI\MainUI_Settings_Crafting.lua"
$settingsCraftingUIText = Get-Content -LiteralPath $settingsCraftingUIPath -Raw
foreach ($issue in (Test-RestockIgnoreSelfGuard -RestockItemBody $restockItemBody -QueueFileText $queueText -SettingsUIFileText $settingsCraftingUIText)) {
	Add-Failure $issue
}

$scannerPath = Join-Path $projectRoot "TradeSkillMaster\LibTSMService\Source\Auction\Classes\Scanner.lua"
$scanHandlerBody = Get-LuaFunctionBody -Lines (Get-Content -LiteralPath $scannerPath) -FunctionPattern 'private\.ScanTimerHandler'
foreach ($issue in (Test-OwnedAuctionScan -Body $scanHandlerBody)) {
	Add-Failure $issue
}

$defaultUIPath = Join-Path $projectRoot "TradeSkillMaster\LibTSMWoW\Source\UI\DefaultUI.lua"
$defaultUIText = Get-Content -LiteralPath $defaultUIPath -Raw
$onModuleLoadMatch = [regex]::Match(
	$defaultUIText,
	'(?s)DefaultUI:OnModuleLoad\(function\(\)\s*\r?\n(?<body>.*?)\r?\nend\)'
)
if (-not $onModuleLoadMatch.Success) {
	Add-Failure "Nie znaleziono ciała DefaultUI:OnModuleLoad()."
} else {
	foreach ($issue in (Test-ClassicVisibilityEvents -Body $onModuleLoadMatch.Groups["body"].Value)) {
		Add-Failure $issue
	}
}

$rescanBody = Get-LuaFunctionBody -Lines $bagTrackingLines -FunctionPattern 'BagTracking\.RescanAllBags'
foreach ($issue in (Test-RescanFlushesQuantityCallbacks -Body $rescanBody)) {
	Add-Failure $issue
}

$craftingUIPath = Join-Path $projectRoot "TradeSkillMaster_Crafting\UI\CraftingUI_Crafting.lua"
$craftingUIText = Get-Content -LiteralPath $craftingUIPath -Raw
$showDelayedMatch = [regex]::Match(
	$craftingUIText,
	'(?s)action == "ACTION_FRAME_SHOW_DELAYED" then(?<body>.*?)\r?\n\telseif action == '
)
if (-not $showDelayedMatch.Success) {
	Add-Failure "Nie znaleziono handlera ACTION_FRAME_SHOW_DELAYED w CraftingUI."
} else {
	foreach ($issue in (Test-CraftingUIOpenRescan -Body $showDelayedMatch.Groups["body"].Value)) {
		Add-Failure $issue
	}
}

$auctionHousePath = Join-Path $projectRoot "TradeSkillMaster\LibTSMWoW\Source\API\AuctionHouse.lua"
$auctionHouseText = Get-Content -LiteralPath $auctionHousePath -Raw
foreach ($issue in (Test-OwnedListLoadGate -FileText $auctionHouseText)) {
	Add-Failure $issue
}

$auctionScannerPath = Join-Path $projectRoot "TradeSkillMaster\LibTSMService\Source\AuctionScan\Classes\Scanner.lua"
$auctionScannerText = Get-Content -LiteralPath $auctionScannerPath -Raw
$craftingCorePath = Join-Path $projectRoot "TradeSkillMaster_Crafting\Service\Core.lua"
$craftingCoreText = Get-Content -LiteralPath $craftingCorePath -Raw
foreach ($issue in (Test-ScanPacing -ScannerText $auctionScannerText -CoreText $craftingCoreText)) {
	Add-Failure $issue
}

$queryUtilPath = Join-Path $projectRoot "TradeSkillMaster\LibTSMService\Source\AuctionScan\Classes\QueryUtil.lua"
$queryUtilText = Get-Content -LiteralPath $queryUtilPath -Raw
foreach ($issue in (Test-ClassBatchQuery -QueryUtilText $queryUtilText)) {
	Add-Failure $issue
}

$queryPath = Join-Path $projectRoot "TradeSkillMaster\LibTSMService\Source\AuctionScan\Classes\Query.lua"
$queryText = Get-Content -LiteralPath $queryPath -Raw
$postScanPath = Join-Path $projectRoot "TradeSkillMaster\Core\Service\Auctioning\PostScan.lua"
$postScanText = Get-Content -LiteralPath $postScanPath -Raw
$cancelScanPath = Join-Path $projectRoot "TradeSkillMaster\Core\Service\Auctioning\CancelScan.lua"
$cancelScanText = Get-Content -LiteralPath $cancelScanPath -Raw
foreach ($issue in (Test-PriceSortEarlyStop -QueryText $queryText -PostScanText $postScanText -CancelScanText $cancelScanText -ScanScannerText $auctionScannerText)) {
	Add-Failure $issue
}
$scanManagerPath = Join-Path $projectRoot "TradeSkillMaster\LibTSMService\Source\AuctionScan\Classes\ScanManager.lua"
$scanManagerText = Get-Content -LiteralPath $scanManagerPath -Raw
foreach ($issue in (Test-ScanPlannerConsumerGuard -QueryText $queryText -ScanManagerText $scanManagerText -PostScanText $postScanText -CancelScanText $cancelScanText -ScannerText $auctionScannerText)) {
	Add-Failure $issue
}

# --- Mutation controls: every check must fail on the known-bad code it replaced ---

$mutations = @(
	@{
		Name = "CraftCastMatching"
		Issues = (Test-CraftCastMatching -BranchText (@(
			'local spellId = nil',
			'if private.craftSpellId and GetSpellInfo(private.craftSpellId) == name then',
			'    spellId = private.craftSpellId',
			'else',
			'    spellId = -1',
			'end'
		) -join "`n"))
	},
	@{
		Name = "BagUpdateDelayedEmulation"
		Issues = (Test-BagUpdateDelayedEmulation `
			-Condition 'LibTSMService.IsPandaClassic() or LibTSMService.IsRetail()' `
			-ThenBody 'private.bagUpdateDelayedTimer = DelayTimer.New("X", private.BagUpdateDelayedHandler)' + "`n" + 'Event.Register("BAG_UPDATE", function() private.bagUpdateDelayedTimer:RunForFrames(0) end)' `
			-ElseBody 'Event.Register("BAG_UPDATE_DELAYED", private.BagUpdateDelayedHandler)')
	},
	@{
		Name = "LoginFullBagScan"
		Issues = (Test-LoginFullBagScan -Body (@(
			'private.BagUpdateHandler(nil, 0)',
			'private.BagUpdateDelayedHandler()'
		) -join "`n"))
	},
	@{
		Name = "RestockRescan"
		Issues = (Test-RestockRescan `
			-Body 'function Queue.RestockGroups(groups)' + "`n" + '    private.db:SetQueryUpdatesPaused(true)' + "`n" + 'end' `
			-FileText '-- no include')
	},
	@{
		Name = "RestockIgnoreSelfGuard"
		Issues = (Test-RestockIgnoreSelfGuard `
			-RestockItemBody (@(
				'function private.RestockItem(itemString)',
				'for player, ignored in pairs(private.settings.ignoreCharacters) do',
				'    if ignored then',
				'        haveQuantity = haveQuantity - AltTracking.GetBagQuantity(itemString, player)',
				'    end',
				'end',
				'end'
			) -join "`n") `
			-QueueFileText '-- no include' `
			-SettingsUIFileText 'tinsert(private.altCharacters, character)')
	},
	@{
		Name = "OwnedAuctionScan"
		Issues = (Test-OwnedAuctionScan -Body (@(
			'function private.ScanTimerHandler()',
			'if not DefaultUI.IsAuctionHouseVisible() then',
			'    return',
			'elseif DefaultUI.IsDefaultOwnedAuctionTabVisible() then',
			'    -- Default UI auctions tab is visible, so scan later',
			'    private.scanTimer:RunForFrames(2)',
			'    return',
			'end',
			'if not ClientInfo.HasFeature(ClientInfo.FEATURES.C_AUCTION_HOUSE) and not AuctionHouse.AreOwnedSortedByOwnerDuration() then',
			'    AuctionHouse.SortOwnedByOwnerDuration()',
			'end',
			'private.ScanOwnedAuctions()',
			'end'
		) -join "`n"))
	},
	@{
		Name = "ClassicVisibilityEvents"
		Issues = (Test-ClassicVisibilityEvents -Body (@(
			'Event.Register("PLAYER_INTERACTION_MANAGER_FRAME_SHOW", private.PlayerInteractionShowHandler)',
			'hooksecurefunc(PlayerInteractionFrameManager, "ShowFrame", private.PlayerInteractionShowHandler)'
		) -join "`n"))
	},
	@{
		Name = "RescanFlushesQuantityCallbacks"
		Issues = (Test-RescanFlushesQuantityCallbacks -Body (@(
			'function BagTracking.RescanAllBags()',
			'    private.slotDB:SetQueryUpdatesPaused(true)',
			'    private.slotDB:SetQueryUpdatesPaused(false)',
			'end'
		) -join "`n"))
	},
	@{
		Name = "CraftingUIOpenRescan"
		Issues = (Test-CraftingUIOpenRescan -Body (@(
			'if action == "ACTION_FRAME_SHOW_DELAYED" then',
			'    local frame = ...',
			'    state.frame = frame',
			'end'
		) -join "`n"))
	},
	@{
		Name = "OwnedListLoadGate"
		Issues = (Test-OwnedListLoadGate -FileText (@(
			'function AuctionHouse.OwnedFullyLoaded()',
			'	return not ClientInfo.HasFeature(ClientInfo.FEATURES.C_AUCTION_HOUSE) or C_AuctionHouse.HasFullOwnedAuctionResults()',
			'end'
		) -join "`n"))
	},
	@{
		Name = "ScanPacing"
		Issues = (Test-ScanPacing `
			-ScannerText (@(
				'local BROWSE_MISSING_INFO_RETRY_DELAY = 0.5',
				'local BROWSE_EMPTY_RETRY_DELAY = 0.25',
				'if (private.sellerWaitCounts[index] or 0) < 2 then'
			) -join "`n") `
			-CoreText '-- no scantrace')
	},
	@{
		Name = "ClassBatchQuery"
		Issues = (Test-ClassBatchQuery -QueryUtilText (@(
			'function private.GenerateClassicQueriesThreaded(itemList, callback)',
			'	local merged = {}',
			'	for _, itemString in ipairs(itemList) do',
			'	end',
			'end'
		) -join "`n"))
	},
	@{
		Name = "PriceSortEarlyStop"
		Issues = (Test-PriceSortEarlyStop `
			-QueryText '-- no getter' `
			-PostScanText (@(
				'if numBuyouts <= 1 then',
				'	isFilterDone = false',
				'end'
			) -join "`n") `
			-CancelScanText '-- no done function' `
			-ScanScannerText '-- no recording')
	},
	@{
		Name = "ScanPlannerConsumerGuard"
		Issues = (Test-ScanPlannerConsumerGuard `
			-QueryText '-- no public terminal API' `
			-ScanManagerText '-- unconditional callbacks' `
			-PostScanText 'query:SetIsBrowseDoneFunction(private.QueryIsBrowseDoneFunction)' `
			-CancelScanText 'query:SetIsBrowseDoneFunction(private.QueryIsBrowseDoneFunction)' `
			-ScannerText 'private.query._browseEndedEarly')
	},
	@{
		Name = "ScanPlannerStandaloneExactCallback"
		Issues = (Test-ScanPlannerConsumerGuard `
			-QueryText 'function AuctionQuery:HasCompletedFullBrowse() end function AuctionQuery:GetEndReason() end' `
			-ScanManagerText 'query:HasCompletedFullBrowse() query:GetEndReason()' `
			-PostScanText 'local scanPlanKind = query:GetScanPlanKind() if not scanPlanKind or scanPlanKind == "EXACT" then end' `
			-CancelScanText 'local scanPlanKind = query:GetScanPlanKind() if not scanPlanKind then end' `
			-ScannerText 'query:HasEndedEarly() query:GetEndReason()')
	}
)
foreach ($mutation in $mutations) {
	# NOTE: PowerShell unrolls single-element collections returned from functions
	# into a scalar (e.g. a String), so re-wrap with @() before counting.
	if (@($mutation.Issues).Count -eq 0) {
		Add-Failure ("Kontrola mutacyjna {0} nie wykrywa znanego błędnego kodu." -f $mutation.Name)
	}
}

if ($failures.Count -gt 0) {
	Write-Host "FAIL: regresje kolejki craftowania i restocku:" -ForegroundColor Red
	foreach ($failure in $failures) {
		Write-Host " - $failure" -ForegroundColor Red
	}
	exit 1
}

Write-Host "PASS: Craft Next rozpoznaje własny cast, torby są skanowane na żywo i przy otwarciu okna profesji, restock widzi świeże dane, widoczność AH działa na zdarzeniach klasycznych, a własne aukcje są skanowane przy widocznej zakładce Auctions."

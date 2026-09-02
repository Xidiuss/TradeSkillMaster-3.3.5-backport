-- ------------------------------------------------------------------------------ --
--                                TradeSkillMaster                                --
--                          https://tradeskillmaster.com                          --
--    All Rights Reserved - Detailed license information included with addon.     --
-- ------------------------------------------------------------------------------ --

local LibTSMService = select(2, ...).LibTSMService
local Scanner = LibTSMService:Init("AuctionScan.Scanner")
local ItemInfo = LibTSMService:Include("Item.ItemInfo")
local ScanUtil = LibTSMService:Include("AuctionScan.Util")
local DelayTimer = LibTSMService:From("LibTSMWoW"):IncludeClassType("DelayTimer")
local AuctionHouse = LibTSMService:From("LibTSMWoW"):Include("API.AuctionHouse")
local Event = LibTSMService:From("LibTSMWoW"):Include("Service.Event")
local DefaultUI = LibTSMService:From("LibTSMWoW"):Include("UI.DefaultUI")
local ClientInfo = LibTSMService:From("LibTSMWoW"):Include("Util.ClientInfo")
local ItemString = LibTSMService:From("LibTSMTypes"):Include("Item.ItemString")
local FSM = LibTSMService:From("LibTSMUtil"):Include("FSM")
local Future = LibTSMService:From("LibTSMUtil"):IncludeClassType("Future")
local Log = LibTSMService:From("LibTSMUtil"):Include("Util.Log")
local Threading = LibTSMService:From("LibTSMTypes"):Include("Threading")
local private = {
	resolveSellers = nil,
	pendingFuture = nil,
	query = nil, ---@type AuctionQuery
	callback = nil,
	browseId = 1,
	browseIsNoScan = false,
	browseIndex = 1,
	browsePendingIndexes = {},
	searchRow = nil,
	useCachedData = nil,
	retryCount = 0,
	browseEmptyRetryCount = 0,
	browseSendThrottleWaitCount = 0,
	browseSendIsThrottleWait = false,
	requestFuture = Future.New("AUCTION_SCANNER_FUTURE"),
	requestResult = nil,
	fsm = nil,
	retryTimer = nil,
	doneTimer = nil,
	updateTimer = nil,
	missingItemIds = {},
	sellerWaitCounts = {},
	sellerWaitStart = nil,
	-- Timing instrumentation toggled by "/tsmcraftdebug scantrace": one line per
	-- completed browse query showing where its time went, plus per-page price and
	-- stack statistics to diagnose whether the server actually returns
	-- price-sorted pages and single-stack auctions.
	scanTrace = {
		t0 = nil, tSend = nil, tResp = nil,
		str = nil, sellerRows = 0,
		pageStats = nil,
		pageReqStart = nil, pendingReqDur = nil,
		targetsSeen = 0, targetsTotal = 0, pagesCount = 0,
		finalBuyoutOrder = nil, finalUnitOrder = nil, finalEndedEarly = nil, finalEndReason = nil,
	},
	-- 3.3.5 diagnostics: row indexes already counted for the current page. Pending
	-- rows are re-processed by retry passes; without this guard each pass would
	-- re-count the row in pageStats AND re-record its price in the monotonicity
	-- check, producing inflated row counts (rows>50) and FALSE order violations.
	-- The guard lives AFTER the noInfo early-return, so a row whose price isn't
	-- valid yet never marks its index and will be recorded once it becomes valid.
	tracedRowIndexes = {},
	-- 3.3.5 diagnostics: per-scan counters for the classic browse processing
	-- pipeline (printed for traced queries, e.g. DE scan)
	classicStats = { seen = 0, noInfo = 0, noLink = 0, badLink = 0, nameSkip = 0, earlyReject = 0, added = 0, nameReject = 0, pendingPasses = 0, tBrowse = 0, tParse = 0, tPopulate = 0 },
	-- 3.3.5 perf: for class-batch queries (empty str with an item set) a name set
	-- built from the target items lets rows be rejected right after the cheap
	-- GetAuctionItemInfo call, before the expensive link fetch/parsing - the
	-- whole category comes back in one page on some cores (1200+ rows) while
	-- only a few dozen items are actually wanted.
	classicNameFilter = nil,
	-- Diagnostics-only target-name set. Unlike classicNameFilter this is built
	-- for CATEGORY, NARROW, and EXACT queries and never changes scan filtering;
	-- it only prevents unrelated category rows from bloating the raw log.
	classicTraceNameFilter = nil,
}
-- 3.3.5 scan pacing: per-query retry cadences. These directly set the per-item
-- cost of post/cancel scans (45-70 items): every pending recheck rounds the wait
-- up to a multiple of these delays, so they are kept low. The client-side
-- CanSendAuctionQuery() gate (not tunable from Lua) is the remaining floor.
local BROWSE_MISSING_INFO_RETRY_DELAY = 0.15
local BROWSE_EMPTY_RETRY_DELAY = 0.1
local BROWSE_EMPTY_RETRY_MAX = 12
-- 3.3.5: how long to wait for owner ("seller") names to arrive after a browse
-- page before substituting "?". Owner data lands on the client a moment after
-- the page itself; time-based (instead of 2 fixed 0.5s passes) resolves at the
-- actual arrival time.
local SELLER_WAIT_MAX_TIME = 0.75
local SEARCH_NOT_READY_RETRY_DELAY = 0.1
local SEARCH_MISSING_ITEM_INFO_RETRY_DELAY = 0.1
local SEARCH_AH_NOT_READY_RETRY_DELAY = 0.5
local SEARCH_MISSING_INFO_RETRY_DELAY = 0.5
local FUTURE_FAILED_RETRY_DELAY = 0.1
local SORT_RETRY_DELAY = 0.5
local BROWSE_SEND_THROTTLE_RETRY_DELAY = 0.1
local BROWSE_SEND_THROTTLE_MAX_WAIT = 30
-- 3.3.5 perf: бюджет времени (мс) на обработку browse-страницы за один кадр.
-- Без него цикл ограничивался только числом pending-предметов: если данные
-- всех лотов были в кэше, страница целиком (сотни/тысячи лотов на ядрах с
-- крупными страницами / GetAll) обрабатывалась за один кадр — каждый лот
-- это дорогие C-вызовы GetAuctionItemInfo/GetAuctionItemLink. Это давало
-- многосекундные фризы на каждом поиске.
local BROWSE_PROCESS_TIME_BUDGET_MS = 25



-- ============================================================================
-- Module Loading
-- ============================================================================

Scanner:OnModuleLoad(function()
	private.retryTimer = DelayTimer.New("AUCTION_SCANNER_RETRY", private.RetryHandler)
	private.doneTimer = DelayTimer.New("AUCTION_SCANNER_DONE", private.RequestDoneHandler)
	private.updateTimer = DelayTimer.New("AUCTION_SCANNER_RETRY", function()
		private.fsm:SetLoggingEnabled(false)
		private.fsm:ProcessEvent("EV_BROWSE_RESULTS_UPDATED")
		private.fsm:SetLoggingEnabled(true)
	end)
	private.requestFuture:SetScript("OnCleanup", function()
		private.doneTimer:Cancel()
		private.fsm:ProcessEvent("EV_CANCEL")
	end)

	if ClientInfo.HasFeature(ClientInfo.FEATURES.C_AUCTION_HOUSE) then
		Event.Register("COMMODITY_SEARCH_RESULTS_UPDATED", function()
			private.fsm:ProcessEvent("EV_SEARCH_RESULTS_UPDATED")
		end)
		Event.Register("ITEM_SEARCH_RESULTS_UPDATED", function()
			private.fsm:ProcessEvent("EV_SEARCH_RESULTS_UPDATED")
		end)
		Event.Register("ITEM_KEY_ITEM_INFO_RECEIVED", function(_, itemId)
			private.fsm:SetLoggingEnabled(false)
			private.fsm:ProcessEvent("EV_ITEM_KEY_INFO_RECEIVED", itemId)
			private.fsm:SetLoggingEnabled(true)
		end)
	else
		Event.Register("AUCTION_ITEM_LIST_UPDATE", function()
			local numAuctions, totalAuctions = AuctionHouse.GetNumAuctions()
			TSMDBG.Log("Scanner", "AUCTION_ITEM_LIST_UPDATE numAuctions=%d totalAuctions=%d", numAuctions or 0, totalAuctions or 0)
			private.updateTimer:RunForFrames(0)
		end)
	end

	private.fsm = FSM.New("AUCTION_SCANNER_FSM")
		:AddState(FSM.NewState("ST_INIT")
			:SetOnEnter(function()
				private.query = nil
				private.resolveSellers = nil
				private.useCachedData = nil
				private.searchRow = nil
				private.callback = nil
				private.retryCount = 0
				private.browseEmptyRetryCount = 0
				private.browseSendThrottleWaitCount = 0
				private.browseSendIsThrottleWait = false
				private.sellerWaitStart = nil
				private.classicNameFilter = nil
				private.classicTraceNameFilter = nil
				private.retryTimer:Cancel()
				if private.pendingFuture then
					private.pendingFuture:Cancel()
					private.pendingFuture = nil
				end
			end)
			:AddTransition("ST_BROWSE_SORT")
			:AddTransition("ST_BROWSE_CHECKING")
			:AddTransition("ST_SEARCH_GET_KEY")
			:AddEvent("EV_START_BROWSE", function(_, query, resolveSellers, callback)
				assert(not private.query)
				-- Debug output disabled for EV_START_BROWSE to reduce chat spam
				-- print(string.format("TSM:EV_START_BROWSE query._str=%s", tostring(query._str)))
				private.query = query
				private.resolveSellers = resolveSellers
				private.browseId = private.browseId + 1
				private.browseIsNoScan = false
				private.callback = callback
				if _G.TSM_SCAN_TRACE then
					private.scanTrace.t0 = GetTime()
					private.scanTrace.tSend = nil
					private.scanTrace.tResp = nil
					private.scanTrace.str = query._str
					private.scanTrace.pageStats = nil
					private.scanTrace.pageReqStart = nil
					private.scanTrace.pendingReqDur = nil
					private.scanTrace.pagesCount = 0
					private.scanTrace.targetsSeen = 0
					private.scanTrace.finalBuyoutOrder = nil
					private.scanTrace.finalUnitOrder = nil
					private.scanTrace.finalEndedEarly = nil
					private.scanTrace.finalEndReason = nil
					wipe(private.tracedRowIndexes)
					local targetsTotal = 0
					for _ in query:ItemIterator() do
						targetsTotal = targetsTotal + 1
					end
					private.scanTrace.targetsTotal = targetsTotal
				end
				private.classicNameFilter = private.BuildClassicNameFilter(query)
				private.classicTraceNameFilter = private.BuildClassicTraceNameFilter(query)
				return "ST_BROWSE_SORT"
			end)
			:AddEvent("EV_START_BROWSE_NO_SCAN", function(_, query, itemKeys, callback)
				assert(ClientInfo.HasFeature(ClientInfo.FEATURES.C_AUCTION_HOUSE))
				assert(not private.query)
				private.query = query
				private.browseId = private.browseId + 1
				private.browseIsNoScan = true
				private.callback = callback
				for _, itemKey in ipairs(itemKeys) do
					local baseItemString = ItemString.GetBaseFromItemKey(itemKey)
					private.query:_ProcessBrowseResult(baseItemString, itemKey)
				end
				return "ST_BROWSE_CHECKING"
			end)
			:AddEvent("EV_START_SEARCH", function(_, query, resolveSellers, useCachedData, searchRow, callback)
				assert(ClientInfo.HasFeature(ClientInfo.FEATURES.C_AUCTION_HOUSE))
				assert(not private.query)
				private.query = query
				private.resolveSellers = resolveSellers
				private.useCachedData = useCachedData
				private.searchRow = searchRow
				private.callback = callback
				private.searchRow:SearchReset()
				return "ST_SEARCH_GET_KEY"
			end)
		)
		:AddState(FSM.NewState("ST_BROWSE_SORT")
			:SetOnEnter(function()
				if not private.query:_SetSort() then
					private.retryTimer:RunForTime(SORT_RETRY_DELAY)
					return
				end
				return "ST_BROWSE_SEND"
			end)
			:AddTransition("ST_BROWSE_SORT")
			:AddTransition("ST_BROWSE_SEND")
			:AddTransition("ST_CANCELING")
			:AddEventTransition("EV_RETRY", "ST_BROWSE_SORT")
			:AddEventTransition("EV_CANCEL", "ST_CANCELING")
		)
		:AddState(FSM.NewState("ST_BROWSE_SEND")
			:SetOnEnter(function()
				if private.MaybeWaitForBrowseSendThrottle() then
					return
				end
				private.scanTrace.pageReqStart = GetTime()
				if _G.TSM_SCAN_TRACE and private.scanTrace.t0 and not private.scanTrace.tSend then
					-- first actual send of this query (after the CanSendQuery gate)
					private.scanTrace.tSend = GetTime()
				end
				private.browseSendIsThrottleWait = false
				private.HandleAuctionHouseWrapperResult(private.query:_SendWowQuery())
			end)
				:AddTransition("ST_BROWSE_SEND")
				:AddTransition("ST_BROWSE_CHECKING")
				:AddTransition("ST_CANCELING")
				:AddEvent("EV_FUTURE_SUCCESS", function()
					if ClientInfo.HasFeature(ClientInfo.FEATURES.C_AUCTION_HOUSE) then
						for _, result in ipairs(AuctionHouse.GetBrowseResults()) do
							local baseItemString = ItemString.GetBaseFromItemKey(result.itemKey)
							private.query:_ProcessBrowseResult(baseItemString, result.itemKey, result.minPrice, result.totalQuantity)
						end
				else
					if private.scanTrace.pageReqStart then
						private.scanTrace.pendingReqDur = GetTime() - private.scanTrace.pageReqStart
					end
					wipe(private.tracedRowIndexes)
					private.browseIndex = 1
					private.sellerWaitStart = nil
					wipe(private.browsePendingIndexes)
					if _G.TSM_SCAN_TRACE and private.scanTrace.t0 then
						private.scanTrace.tResp = GetTime()
					end
					private.ScanTraceFinishPage()
				end
				return "ST_BROWSE_CHECKING"
			end)
			:AddEventTransition("EV_RETRY", "ST_BROWSE_SEND")
			:AddEventTransition("EV_CANCEL", "ST_CANCELING")
		)
		:AddState(FSM.NewState("ST_BROWSE_CHECKING")
			:SetOnEnter(function()
				-- Debug output disabled for ST_BROWSE_CHECKING to reduce chat spam
				-- print(string.format("TSM:ST_BROWSE_CHECKING browseIndex=%d numAuctions=%d", private.browseIndex, AuctionHouse.GetNumAuctions() or 0))
				if not private.query:_BrowseIsPageValid() then
					-- This page isn't valid, so go to the next page
					return "ST_BROWSE_REQUEST_MORE"
				elseif not private.CheckBrowseResults() then
					-- Results aren't valid yet, so check again
					private.retryTimer:RunForTime(BROWSE_MISSING_INFO_RETRY_DELAY)
					return
				end
				-- We're done with this set of browse results
				if private.callback then
					private.callback(private.query)
				end
				if private.browseIsNoScan or private.query:_BrowseIsDone() then
					-- We're done
					return "ST_BROWSE_DONE"
				else
					-- move on to the next page
					return "ST_BROWSE_REQUEST_MORE"
				end
			end)
			:AddTransition("ST_BROWSE_CHECKING")
			:AddTransition("ST_BROWSE_DONE")
			:AddTransition("ST_BROWSE_REQUEST_MORE")
			:AddTransition("ST_CANCELING")
			:AddEventTransition("EV_RETRY", "ST_BROWSE_CHECKING")
			:AddEventTransition("EV_BROWSE_RESULTS_UPDATED", "ST_BROWSE_CHECKING")
			:AddEventTransition("EV_CANCEL", "ST_CANCELING")
			:AddEvent("EV_ITEM_KEY_INFO_RECEIVED", function(_, itemId)
				if not next(private.missingItemIds) then
					return
				end
				private.missingItemIds[itemId] = nil
				if not next(private.missingItemIds) then
					private.retryTimer:Cancel()
					return "ST_BROWSE_CHECKING"
				end
			end)
		)
		:AddState(FSM.NewState("ST_BROWSE_REQUEST_MORE")
			:SetOnEnter(function(_, isRetry)
				if private.query:_BrowseIsDone(isRetry) then
					return "ST_BROWSE_CHECKING"
				end
				if private.MaybeWaitForBrowseSendThrottle() then
					return
				end
				if private.browseSendIsThrottleWait then
					isRetry = false
					private.browseSendIsThrottleWait = false
				end
				private.scanTrace.pageReqStart = GetTime()
				private.HandleAuctionHouseWrapperResult(private.query:_BrowseRequestMore(isRetry))
			end)
			:AddTransition("ST_BROWSE_REQUEST_MORE")
			:AddTransition("ST_BROWSE_CHECKING")
			:AddTransition("ST_CANCELING")
			:AddEvent("EV_FUTURE_SUCCESS", function(_, ...)
				if ClientInfo.HasFeature(ClientInfo.FEATURES.C_AUCTION_HOUSE) then
					local newResults = ...
					for _, result in ipairs(newResults) do
						local baseItemString = ItemString.GetBaseFromItemKey(result.itemKey)
						private.query:_ProcessBrowseResult(baseItemString, result.itemKey, result.minPrice, result.totalQuantity)
					end
				else
					if private.scanTrace.pageReqStart then
						private.scanTrace.pendingReqDur = GetTime() - private.scanTrace.pageReqStart
					end
					wipe(private.tracedRowIndexes)
					private.ScanTraceFinishPage()
					private.browseIndex = 1
					private.sellerWaitStart = nil
					wipe(private.browsePendingIndexes)
				end
				return "ST_BROWSE_CHECKING"
			end)
			:AddEvent("EV_RETRY", function()
				if private.browseSendIsThrottleWait then
					return "ST_BROWSE_REQUEST_MORE"
				end
				return "ST_BROWSE_REQUEST_MORE", true
			end)
			:AddEventTransition("EV_CANCEL", "ST_CANCELING")
		)
		:AddState(FSM.NewState("ST_BROWSE_DONE")
			:SetOnEnter(function()
				-- Stash the query's final state BEFORE ST_INIT clears it - the done
				-- timer fires on the next frame, after private.query is already nil.
				if private.query then
					private.scanTrace.finalBuyoutOrder = private.query:IsBuyoutOrdered() and true or false
					private.scanTrace.finalUnitOrder = private.query:IsPriceSorted() and true or false
					private.scanTrace.finalEndedEarly = private.query:HasEndedEarly() and true or false
					private.scanTrace.finalEndReason = private.query:GetEndReason()
				end
				private.HandleRequestDone(true)
				return "ST_INIT"
			end)
			:AddTransition("ST_INIT")
		)
		:AddState(FSM.NewState("ST_SEARCH_GET_KEY")
			:SetOnEnter(function()
				assert(ClientInfo.HasFeature(ClientInfo.FEATURES.C_AUCTION_HOUSE))
				if not private.searchRow:SearchIsReady() then
					private.retryTimer:RunForTime(SEARCH_NOT_READY_RETRY_DELAY)
					return
				end
				return "ST_SEARCH_SEND"
			end)
			:AddTransition("ST_SEARCH_GET_KEY")
			:AddTransition("ST_SEARCH_SEND")
			:AddTransition("ST_CANCELING")
			:AddEventTransition("EV_FUTURE_SUCCESS", "ST_SEARCH_SEND")
			:AddEventTransition("EV_RETRY", "ST_SEARCH_GET_KEY")
			:AddEventTransition("EV_CANCEL", "ST_CANCELING")
		)
		:AddState(FSM.NewState("ST_SEARCH_SEND")
			:SetOnEnter(function()
				assert(ClientInfo.HasFeature(ClientInfo.FEATURES.C_AUCTION_HOUSE))
				if not DefaultUI.IsAuctionHouseVisible() then
					return "ST_CANCELING"
				end
				if private.useCachedData and private.searchRow:HasCachedSearchData() then
					return "ST_SEARCH_REQUEST_MORE"
				end
				local future, delayTime = private.searchRow:SearchSend()
				if future then
					private.HandleAuctionHouseWrapperResult(future)
				else
					if not delayTime then
						Log.Err("Failed to send search query - retrying")
						delayTime = SEARCH_AH_NOT_READY_RETRY_DELAY
					end
					-- Try again after a delay
					private.retryTimer:RunForTime(delayTime)
				end
			end)
			:AddTransition("ST_SEARCH_SEND")
			:AddTransition("ST_SEARCH_REQUEST_MORE")
			:AddTransition("ST_CANCELING")
			:AddEventTransition("EV_FUTURE_SUCCESS", "ST_SEARCH_REQUEST_MORE")
			:AddEventTransition("EV_RETRY", "ST_SEARCH_SEND")
			:AddEventTransition("EV_CANCEL", "ST_CANCELING")
		)
		:AddState(FSM.NewState("ST_SEARCH_REQUEST_MORE")
			:SetOnEnter(function()
				assert(ClientInfo.HasFeature(ClientInfo.FEATURES.C_AUCTION_HOUSE))
				local baseItemString = private.searchRow:GetBaseItemString()
				-- Get if the item is a commodity or not
				local isCommodity = ItemInfo.IsCommodity(baseItemString)
				if isCommodity == nil then
					private.retryTimer:RunForTime(SEARCH_MISSING_ITEM_INFO_RETRY_DELAY)
					return
				end

				local isDone, future = private.searchRow:SearchCheckStatus()
				if isDone then
					return "ST_SEARCH_CHECKING"
				elseif future then
					private.HandleAuctionHouseWrapperResult(future)
				else
					private.retryTimer:RunForTime(SEARCH_AH_NOT_READY_RETRY_DELAY)
				end
			end)
			:AddTransition("ST_SEARCH_SEND")
			:AddTransition("ST_SEARCH_CHECKING")
			:AddTransition("ST_CANCELING")
			:AddEventTransition("EV_FUTURE_SUCCESS", "ST_SEARCH_CHECKING")
			:AddEventTransition("EV_RETRY", "ST_SEARCH_SEND")
			:AddEventTransition("EV_CANCEL", "ST_CANCELING")
		)
		:AddState(FSM.NewState("ST_SEARCH_CHECKING")
			:SetOnEnter(function()
				assert(ClientInfo.HasFeature(ClientInfo.FEATURES.C_AUCTION_HOUSE))
				private.retryTimer:Cancel()
				private.searchRow:PopulateSubRows(private.browseId)

				-- check if all the sub rows have their data
				local missingInfo = false
				for _, subRow in private.searchRow:SubRowIterator(true) do
					if not subRow:HasRawData() or not subRow:HasItemString() then
						missingInfo = true
					elseif private.resolveSellers and not subRow:HasOwners() and not private.query:_IsFiltered(subRow, true) then
						-- Waiting for owner info
						-- Currently can't rely on owner info as of 9.2.7, so limit the retries for it
						if not ClientInfo.HasFeature(ClientInfo.FEATURES.C_AUCTION_HOUSE) or private.retryCount <= 10 then
							missingInfo = true
						end
					end
				end

				if missingInfo and private.retryCount >= 100 then
					-- Out of retries, so give up
					return "ST_SEARCH_DONE", false
				elseif missingInfo then
					-- We'll try again
					private.retryCount = private.retryCount + 1
					private.retryTimer:RunForTime(SEARCH_MISSING_INFO_RETRY_DELAY)
					return
				end

				-- Filter the sub rows we don't care about
				private.searchRow:FilterSubRows(private.query)

				if private.callback then
					private.callback(private.query, private.searchRow)
				end
				if private.searchRow:SearchNext() then
					-- there is more to search
					return "ST_SEARCH_GET_KEY"
				else
					-- scanned everything
					return "ST_SEARCH_DONE", true
				end
			end)
			:AddTransition("ST_SEARCH_GET_KEY")
			:AddTransition("ST_SEARCH_CHECKING")
			:AddTransition("ST_SEARCH_DONE")
			:AddTransition("ST_CANCELING")
			:AddEventTransition("EV_RETRY", "ST_SEARCH_CHECKING")
			:AddEventTransition("EV_SEARCH_RESULTS_UPDATED", "ST_SEARCH_CHECKING")
			:AddEventTransition("EV_CANCEL", "ST_CANCELING")
		)
		:AddState(FSM.NewState("ST_SEARCH_DONE")
			:SetOnEnter(function(_, result)
				assert(ClientInfo.HasFeature(ClientInfo.FEATURES.C_AUCTION_HOUSE))
				private.HandleRequestDone(result)
				return "ST_INIT"
			end)
			:AddTransition("ST_INIT")
		)
		:AddState(FSM.NewState("ST_CANCELING")
			:SetOnEnter(function()
				private.doneTimer:Cancel()
				return "ST_INIT"
			end)
			:AddTransition("ST_INIT")
		)
		:Init("ST_INIT", nil)
end)



-- ============================================================================
-- Module Functions
-- ============================================================================

---Starts a browse scan.
---@param query AuctionQuery The query
---@param resolveSellers boolean Whether or not to resolve seller names
---@param callback fun(query: AuctionQuery, row: AuctionRow) A function to call with results
---@return Future
function Scanner.Browse(query, resolveSellers, callback)
	if not private.WaitForFutureReady() then
		if TSMDBG then TSMDBG.Warn("Scanner", "Browse: WaitForFutureReady FAILED, returning nil") end
		return nil
	end
	if TSMDBG then TSMDBG.Log("Scanner", "Browse: starting future for new browse") end
	private.requestFuture:Start()
	private.fsm:ProcessEvent("EV_START_BROWSE", query, resolveSellers, callback)
	return private.requestFuture
end

---Starts a browse scan without issuing a new query to the game.
---@param query AuctionQuery The query
---@param itemKeys ItemKey[] The item keys to browse for
---@param callback fun(query: AuctionQuery, row: AuctionRow) A function to call with results
---@return Future
function Scanner.BrowseNoScan(query, itemKeys, callback)
	assert(ClientInfo.HasFeature(ClientInfo.FEATURES.C_AUCTION_HOUSE))
	if not private.WaitForFutureReady() then
		return nil
	end
	private.requestFuture:Start()
	private.fsm:ProcessEvent("EV_START_BROWSE_NO_SCAN", query, itemKeys, callback)
	return private.requestFuture
end

-- 3.3.5: requestFuture is shared across all browse callers. When two threads
-- (e.g. FILTER_SEARCH and AUCTION_SCAN_FIND) want to scan back-to-back, the
-- second one hits assert(self._state == STATE.RESET) inside Future:Start.
-- Wait briefly for the previous browse to finish before we Start ours.
function private.WaitForFutureReady()
	if private.requestFuture:IsReady() then
		return true
	end
	if TSMDBG then TSMDBG.Log("Scanner", "WaitForFutureReady: future busy, yielding...") end
	local waitStart = GetTime()
	local yields = 0
	while not private.requestFuture:IsReady() do
		Threading.Yield(true)
		yields = yields + 1
		if GetTime() - waitStart > 5 then
			if TSMDBG then TSMDBG.Warn("Scanner", "WaitForFutureReady: timeout after %d yields, %.2fs", yields, GetTime() - waitStart) end
			return false
		end
	end
	if TSMDBG then TSMDBG.Log("Scanner", "WaitForFutureReady: ready after %d yields, %.2fs", yields, GetTime() - waitStart) end
	return true
end

---Starts a search.
---@param query AuctionQuery The query
---@param resolveSellers boolean Whether or not to resolve seller names
---@param useCachedData boolean Use cached data
---@param browseRow AuctionRow The auction row to search for
---@param callback fun(query: AuctionQuery, row: AuctionRow) A function to call with results
---@return Future
function Scanner.Search(query, resolveSellers, useCachedData, browseRow, callback)
	assert(ClientInfo.HasFeature(ClientInfo.FEATURES.C_AUCTION_HOUSE))
	private.requestFuture:Start()
	private.fsm:ProcessEvent("EV_START_SEARCH", query, resolveSellers, useCachedData, browseRow, callback)
	return private.requestFuture
end

---Cancels any in progress scan.
function Scanner.Cancel()
	-- 3.3.5 fix: also skip when the future is already DONE (resolved but not yet
	-- cleaned up), which happens when cancel races the done timer on AH close;
	-- calling Done() twice trips the Future.lua:91 assertion
	if private.requestFuture:IsReady() or private.requestFuture:IsDone() then
		return
	end
	private.requestFuture:Done(false)
end

---Cancels and discards any active browse so that a higher-priority operation
---(typically per-item find) can take over the AH query channel without racing
---with a long FILTER_SEARCH browse.
---3.3.5: BrowseAndFind operations share `private.requestFuture` and the
---underlying QueryAuctionItems channel, so we must explicitly preempt.
---ВАЖНО: вызывать ИЗ thread context (например _FindAuctionThreadedClassic).
---Future:Done синхронно резюмирует ожидающий thread, что нарушает Thread.lua:184
---assertion (private.runningThread должен быть nil). Поэтому ставим cancel
---через doneTimer (RunForTime(0)) — он отстрелит на следующем tick'е, когда
---текущий thread уже отдаст квант. После таймера нужно дождаться RESET.
function Scanner.PreemptForFind()
	if private.requestFuture:IsReady() then
		return false
	end
	if TSMDBG then TSMDBG.Log("Scanner", "PreemptForFind: scheduling cancel of active browse") end
	private.requestResult = false
	private.doneTimer:RunForTime(0)
	return true
end

---Returns true if the requestFuture is in RESET (no scan active).
---Public mirror of WaitForFutureReady's check, used by ScanManager to wait
---out a preempted browse before issuing a new query.
function Scanner.IsFutureReady()
	return private.requestFuture:IsReady()
end



-- ============================================================================
-- Private Helper Functions
-- ============================================================================

function private.PendingFutureDoneHandler()
	local result = private.pendingFuture:GetValue()
	private.pendingFuture = nil
	if result then
		private.fsm:ProcessEvent("EV_FUTURE_SUCCESS", result)
	else
		private.retryTimer:RunForTime(FUTURE_FAILED_RETRY_DELAY)
	end
end

---Builds a lowercase name set from the query's items for cheap row rejection on
---class-batch queries (empty str with an item set). Returns nil when not
---applicable (name queries already filter by str; queries without items or with
---unresolvable item names fall back to the full pipeline).
---@param query AuctionQuery
---@return table<string,true>? nameSet
function private.BuildClassicNameFilter(query)
	if ClientInfo.HasFeature(ClientInfo.FEATURES.C_AUCTION_HOUSE) then
		return nil
	end
	if query._str ~= "" or not query._items or not next(query._items) then
		return nil
	end
	local nameSet = nil
	for itemString in query:ItemIterator() do
		local name = ItemInfo.GetName(itemString)
		if name then
			if not nameSet then
				nameSet = {}
			end
			nameSet[strlower(name)] = true
		end
	end
	return nameSet
end

---Builds a target-name set used exclusively by raw scan diagnostics. Every
---classic planned query carries its target item set, including name-based
---NARROW and EXACT queries, so this filter stays small without affecting which
---rows enter the actual scanner pipeline.
---@param query AuctionQuery
---@return table<string,true>? nameSet
function private.BuildClassicTraceNameFilter(query)
	if ClientInfo.HasFeature(ClientInfo.FEATURES.C_AUCTION_HOUSE) or not _G.TSM_SCAN_TRACE then
		return nil
	end
	local nameSet = nil
	for itemString in query:ItemIterator() do
		local name = ItemInfo.GetName(itemString)
		if name then
			if not nameSet then
				nameSet = {}
			end
			nameSet[strlower(name)] = true
		end
	end
	return nameSet
end

function private.RetryHandler()
	private.fsm:SetLoggingEnabled(false)
	private.fsm:ProcessEvent("EV_RETRY")
	private.fsm:SetLoggingEnabled(true)
end

---Prints the completed page's statistics (scantrace) and resets them for the
---next page. buyout and unit orderings are reported independently: buyout order
---is what a bounded early-stop needs (future rows can't be cheaper than
--- maxBuyout / maxStack); unit order is what first-seen conclusions need.
function private.ScanTraceFinishPage()
	if not _G.TSM_SCAN_TRACE then
		return
	end
	local ps = private.scanTrace.pageStats
	private.scanTrace.pageStats = nil
	if ps then
		private.scanTrace.pagesCount = (private.scanTrace.pagesCount or 0) + 1
		local query = private.query
		local targetsTotal = private.scanTrace.targetsTotal or 0
		local targetsSeen = 0
		if query then
			for itemString in query:ItemIterator() do
				local row = query:_GetBrowseResults(itemString)
				if row and row:GetNumSubRows() > 0 then
					targetsSeen = targetsSeen + 1
				end
			end
		else
			targetsSeen = private.scanTrace.targetsSeen or 0
		end
		local newTargets = targetsSeen - (private.scanTrace.targetsSeen or 0)
		private.scanTrace.targetsSeen = targetsSeen
		local message = ("[TSM ScanTrace] page=%d rows=%d req=%s | buyout[%s..%s] %s | unit[%s..%s] %s | qtyMax=%d stacksGt1=%d | targets %d/%d (+%d)"):format(
			ps.page,
			ps.rows,
			ps.req and string.format("%.2fs", ps.req) or "-",
			ps.minBuyout and string.format("%.4g", ps.minBuyout) or "-",
			ps.maxBuyout and string.format("%.4g", ps.maxBuyout) or "-",
			query and (query:IsBuyoutOrdered() and "OK" or "VIOLATED") or (private.scanTrace.finalBuyoutOrder == nil and "?" or (private.scanTrace.finalBuyoutOrder and "OK" or "VIOLATED")),
			ps.minUnit and string.format("%.4g", ps.minUnit) or "-",
			ps.maxUnit and string.format("%.4g", ps.maxUnit) or "-",
			query and (query:IsPriceSorted() and "OK" or "VIOLATED") or (private.scanTrace.finalUnitOrder == nil and "?" or (private.scanTrace.finalUnitOrder and "OK" or "VIOLATED")),
			ps.qtyMax or 0,
			ps.stacksGt1 or 0,
			targetsSeen,
			targetsTotal,
			newTargets
		)
		TSMDBG.PriceLogTrace(message)
	end
end

---Returns true when a classic browse send must wait for CanSendAuctionQuery().
---@return boolean
function private.MaybeWaitForBrowseSendThrottle()
	if ClientInfo.HasFeature(ClientInfo.FEATURES.C_AUCTION_HOUSE) then
		return false
	end
	if private.browseSendThrottleWaitCount < BROWSE_SEND_THROTTLE_MAX_WAIT and not AuctionHouse.CanSendQuery() then
		private.browseSendThrottleWaitCount = private.browseSendThrottleWaitCount + 1
		private.browseSendIsThrottleWait = true
		private.retryTimer:RunForTime(BROWSE_SEND_THROTTLE_RETRY_DELAY)
		return true
	end
	private.browseSendThrottleWaitCount = 0
	return false
end

function private.RequestDoneHandler()
	local result = private.requestResult
	private.requestResult = nil
	if _G.TSM_SCAN_TRACE and private.scanTrace.t0 then
		private.ScanTraceFinishPage()
		local tr = private.scanTrace
		local tDone = GetTime()
		local sellerRows = 0
		for _ in pairs(private.sellerWaitCounts) do
			sellerRows = sellerRows + 1
		end
		local message = ("[TSM ScanTrace] q=\"%s\" total=%.2fs gate+send=%.2fs send->resp=%.2fs resp->done=%.2fs emptyRetry=%d/%d sellerWaitRows=%d pages=%d endedEarly=%s reason=%s unresolved=%d buyoutOrder=%s unitOrder=%s targets=%d/%d result=%s"):format(
			tostring(tr.str),
			tDone - tr.t0,
			(tr.tSend or tDone) - tr.t0,
			tr.tResp and tr.tSend and (tr.tResp - tr.tSend) or 0,
			tr.tResp and (tDone - tr.tResp) or 0,
			private.browseEmptyRetryCount or 0,
			BROWSE_EMPTY_RETRY_MAX,
			sellerRows,
			tr.pagesCount or 0,
			tostring(tr.finalEndedEarly == true),
			tr.finalEndReason or "-",
			max((tr.targetsTotal or 0) - (tr.targetsSeen or 0), 0),
			tr.finalBuyoutOrder == nil and "?" or (tr.finalBuyoutOrder and "OK" or "VIOLATED"),
			tr.finalUnitOrder == nil and "?" or (tr.finalUnitOrder and "OK" or "VIOLATED"),
			tr.targetsSeen or 0,
			tr.targetsTotal or 0,
			tostring(result)
		)
		TSMDBG.PriceLogTrace(message)
		tr.t0 = nil
	end
	-- 3.3.5 fix: the done timer fires on the NEXT frame, and the future can be
	-- resolved in between (e.g. the AH closes mid-scan -> Scanner.Cancel() calls
	-- Done(false) directly, or a preempt resolves it first). Calling Done() on a
	-- future that isn't STARTED trips the Future.lua:91 assertion, so bail out if
	-- there's nothing left to resolve.
	if private.requestFuture:IsReady() or private.requestFuture:IsDone() then
		return
	end
	private.requestFuture:Done(result)
end

function private.HandleAuctionHouseWrapperResult(future)
	if future then
		private.pendingFuture = future
		private.pendingFuture:SetScript("OnDone", private.PendingFutureDoneHandler)
	else
		private.retryTimer:RunForTime(FUTURE_FAILED_RETRY_DELAY)
	end
end

function private.HandleRequestDone(result)
	private.requestResult = result
	if TSMDBG then TSMDBG.Log("Scanner", "HandleRequestDone result=%s hasQuery=%s",
		tostring(result), tostring(private.query ~= nil)) end
	-- 3.3.5 local DB: запись данных скана делается ТУТ, после успешного browse,
	-- ровно один раз на скан. _UpdateData в ScrollTable дёргается на любой
	-- render-update и для записи не годится.
	-- 3.3.5 ROOT-FIX (Sniper "лот появляется и через 5 сек пропадает"):
	-- НЕ записываем в AuctionDB результаты частичного скана. Sniper сканирует
	-- ТОЛЬКО последнюю страницу (SetPage("LAST") + SetAccumulate) — это по
	-- определению самые дешёвые/недооценённые лоты. Запись их в DBMarket/
	-- DBMinBuyout каждые 5 сек занижает рыночную цену → SniperOperation.GetMaxPrice
	-- (порог снайпа) падает → на следующем проходе лот больше не проходит порог
	-- и ИСЧЕЗАЕТ из списка (само-отравление рынка по таймеру рескана). Полные
	-- сканы и поиск по одному предмету (без _specifiedPage/_accumulate) пишутся
	-- как раньше.
	local isPartialScan = private.query and (
		private.query._accumulate
		or private.query._specifiedPage ~= nil
		or private.query._browseEndedEarly
	)
	if result and private.query and not isPartialScan and _G.TSM_AuctionDB_RecordScan then
		local ok, err = pcall(private.RecordScanResults, private.query)
		if not ok and _G.TSMDebugDB then
			_G.TSMDebugDB.auctiondb_local = _G.TSMDebugDB.auctiondb_local or {}
			table.insert(_G.TSMDebugDB.auctiondb_local, "RecordScanResults ERR: "..tostring(err))
			if TSMDBG then TSMDBG.Warn("Scanner", "RecordScanResults ERR: %s", tostring(err)) end
		end
	end
	-- Delay a bit so that we complete our current FSM transition
	private.doneTimer:RunForTime(0)
end

-- 3.3.5: записать сводку browse-скана в локальную DB (TradeSkillMaster_AuctionDB).
-- Собирает minBuyout / marketValue / numAuctions per baseItemString и зовёт
-- _G.TSM_AuctionDB_RecordScan({[is]={mb=N, mv=N, na=N}}).
function private.RecordScanResults(query)
	local scanData = {}
	local count = 0
	local prices = {}
	for baseItemString, row in query:BrowseResultsIterator() do
		local minBuyout, auctionCount = nil, 0
		wipe(prices)
		for _, subRow in row:SubRowIterator() do
			if subRow.HasRawData and subRow:HasRawData() then
				local _, itemBuyout = subRow:GetBuyouts()
				local _, numAuctions = subRow:GetQuantities()
				if itemBuyout and itemBuyout > 0 then
					if not minBuyout or itemBuyout < minBuyout then
						minBuyout = itemBuyout
					end
					-- одна точка на АУКЦИОН (как в оригинальном TSM), а не на
					-- единицу в стаке: иначе один дешёвый стак 20 шт даёт 20
					-- точек и полностью захватывает нижний перцентиль выборки,
					-- отравляя marketValue
					for _ = 1, numAuctions do
						prices[#prices + 1] = itemBuyout
					end
				end
				-- na = кол-во аукционов (лотов), а не единиц товара.
				-- Тултип "N auctions" должен означать именно лоты.
				auctionCount = auctionCount + numAuctions
			end
		end
		if minBuyout and minBuyout > 0 then
			scanData[baseItemString] = {
				mb = minBuyout,
				mv = ScanUtil.CalcMarketValue(prices) or minBuyout,
				na = auctionCount > 0 and auctionCount or nil,
				nsamples = #prices,
			}
			count = count + 1
		end
	end
	if count > 0 then
		_G.TSM_AuctionDB_RecordScan(scanData)
		-- 3.3.5: also feed the in-memory AuctionDB holder so DBMinBuyout /
		-- DBMarket reflect this scan immediately (e.g. right after searching a
		-- single item), instead of only after the next /reload when the
		-- SavedVariable is re-read into the holder.
		if _G.TSM_AuctionDB_RecordLocalScanResults then
			_G.TSM_AuctionDB_RecordLocalScanResults(scanData)
		end
		if _G.TSMDebugDB then
			_G.TSMDebugDB.auctiondb_local = _G.TSMDebugDB.auctiondb_local or {}
			-- sliding window: храним только последние 200 записей
			local log = _G.TSMDebugDB.auctiondb_local
			while #log > 200 do
				table.remove(log, 1)
			end
			table.insert(log, string.format("[%s] RecordScan items=%d", date("%H:%M:%S"), count))
		end
	end
end

function private.CheckBrowseResults()
	if not ClientInfo.HasFeature(ClientInfo.FEATURES.C_AUCTION_HOUSE) then
		-- Process as many auctions as we can
		local numAuctions = AuctionHouse.GetNumAuctions()
		if private.browseIndex == 1 and #private.browsePendingIndexes == 0 then
			-- new scan starting: reset the diagnostics counters
			local cs = private.classicStats
			cs.seen, cs.noInfo, cs.noLink, cs.badLink, cs.nameSkip, cs.earlyReject, cs.added = 0, 0, 0, 0, 0, 0, 0
			cs.pendingPasses, cs.tBrowse, cs.tParse, cs.tPopulate, cs.nameReject = 0, 0, 0, 0, 0
			wipe(private.sellerWaitCounts)
		end
		-- Some 3.3.5a cores briefly return an empty page right after a browse query.
		-- Retry a few times instead of immediately showing an empty result set.
		if numAuctions > 0 then
			private.browseEmptyRetryCount = 0
		elseif private.query and private.browseEmptyRetryCount < BROWSE_EMPTY_RETRY_MAX then
			private.browseEmptyRetryCount = private.browseEmptyRetryCount + 1
			private.retryTimer:RunForTime(BROWSE_EMPTY_RETRY_DELAY)
			TSMDBG.Log("Scanner", "Classic browse returned empty page; retrying (%d/%d)", private.browseEmptyRetryCount, BROWSE_EMPTY_RETRY_MAX)
			return false
		elseif numAuctions == 0 and private.query and private.query:GetScanPlanKind() == "CATEGORY" and private.query:GetPage() == 0 then
			-- An empty first CATEGORY response cannot be distinguished from a
			-- delayed 3.3.5 browse payload. Never let it suppress the narrower
			-- fallback plan as a false FULL result.
			private.query:_SetBrowseEndReason("INCOMPLETE")
			TSMDBG.Log("Scanner", "Classic CATEGORY stayed empty after retries; falling back")
		end
		for i = #private.browsePendingIndexes, 1, -1 do
			local index = private.browsePendingIndexes[i]
			if private.ProcessBrowseResultClassic(index) then
				tremove(private.browsePendingIndexes, i)
			end
		end
		-- 3.3.5 perf: обрабатываем не дольше BROWSE_PROCESS_TIME_BUDGET_MS за
		-- вызов; при исчерпании бюджета продолжаем на следующем кадре через
		-- updateTimer (retryTimer от FSM с его 0.5с задержкой перекрывается
		-- более быстрым тиком updateTimer — EV_BROWSE_RESULTS_UPDATED вернёт
		-- нас в ST_BROWSE_CHECKING немедленно)
		local budgetStart = debugprofilestop()
		local budgetExhausted = false
		local index = private.browseIndex
		while index <= numAuctions and #private.browsePendingIndexes < 50 do
			if not private.ProcessBrowseResultClassic(index) then
				tinsert(private.browsePendingIndexes, index)
			end
			index = index + 1
			if debugprofilestop() - budgetStart > BROWSE_PROCESS_TIME_BUDGET_MS then
				budgetExhausted = index <= numAuctions
				break
			end
		end
		private.browseIndex = index
		if budgetExhausted then
			TSMDBG.Log("Scanner", "Browse page budget exhausted at index %d/%d; continuing next frame", private.browseIndex - 1, numAuctions)
			private.updateTimer:RunForFrames(1)
			return false
		end
		if private.browseIndex <= numAuctions or #private.browsePendingIndexes > 0 then
			private.classicStats.pendingPasses = private.classicStats.pendingPasses + 1
			return false
		end
	end

	-- Attempt to populate the browse results
	wipe(private.missingItemIds)
	local populated, numRemoved = nil, 0
	if ClientInfo.HasFeature(ClientInfo.FEATURES.C_AUCTION_HOUSE) then
		populated, numRemoved = private.query:_PopulateBrowseData(private.missingItemIds)
		if numRemoved > 0 then
			Log.Info("Removed %d results while populing data", numRemoved)
		end
		if not populated then
			return false
		end
	else
		TSMDBG.Log("Scanner", "Calling _PopulateBrowseData (classic, no-wait)")
		populated, numRemoved = private.query:_PopulateBrowseData(private.missingItemIds)
		if numRemoved > 0 then
			Log.Info("Removed %d results while populing data", numRemoved)
		end
		populated = true
	end

	-- Filter the results
	numRemoved = private.query:_FilterBrowseResults()
	if numRemoved > 0 then
		Log.Info("Removed %d filtered results", numRemoved)
		TSMDBG.Log("Scanner", "Filtered out %d results", numRemoved)
	end

	-- Count final results
	local totalResults = 0
	for _ in private.query:BrowseResultsIterator() do
		totalResults = totalResults + 1
	end
	TSMDBG.Log("Scanner", "Final results count=%d", totalResults)
	TSMDBG.TimeEnd("Scanner:CheckBrowseResults")

	return true
end

function private.ProcessBrowseResultClassic(index)
	local cs = private.classicStats
	cs.seen = cs.seen + 1
	local tPhase = debugprofilestop()
	local rawName, itemLink, stackSize, timeLeft, buyout, seller = AuctionHouse.GetBrowseResult(index)
	cs.tBrowse = cs.tBrowse + (debugprofilestop() - tPhase)

	if not rawName or rawName == "" or not buyout or not stackSize or not timeLeft then
		cs.noInfo = cs.noInfo + 1
		return false
	end

	-- Record every row's unit price and stack buyout (before any name/item
	-- filtering, since the page ordering is global) so the query can verify both
	-- orderings independently while pages arrive. Counted/recorded ONCE per row
	-- index per page (retries of pending rows are skipped) - but only rows whose
	-- price is already valid mark their index, so noInfo rows still get recorded
	-- on a later retry once their data arrives.
	if buyout > 0 and stackSize > 0 then
		if not private.tracedRowIndexes[index] then
			private.tracedRowIndexes[index] = true
			local unitBuyout = buyout / stackSize
			private.query:_RecordBrowseUnitPrice(unitBuyout, buyout)
			if _G.TSM_SCAN_TRACE then
				if private.classicTraceNameFilter and private.classicTraceNameFilter[strlower(rawName)] then
					TSMDBG.PriceLogRawAuction({
						queryKind = private.query:GetScanPlanKind() or "LEGACY",
						queryText = private.query._str or "",
						page = private.query._page or 0,
						rowIndex = index,
						rawName = rawName,
						itemLink = itemLink,
						stackSize = stackSize,
						stackBuyout = buyout,
						unitBuyout = unitBuyout,
						seller = seller,
						timeLeft = timeLeft,
						hasItemLink = itemLink and true or false,
					})
				end
				local ps = private.scanTrace.pageStats
				if not ps then
					ps = { rows = 0, minUnit = nil, maxUnit = nil, minBuyout = nil, maxBuyout = nil, qtyMax = 0, stacksGt1 = 0, req = private.scanTrace.pendingReqDur, page = private.query._page or 0 }
					private.scanTrace.pageStats = ps
				end
				ps.rows = ps.rows + 1
				if not ps.minUnit or unitBuyout < ps.minUnit then
					ps.minUnit = unitBuyout
				end
				if not ps.maxUnit or unitBuyout > ps.maxUnit then
					ps.maxUnit = unitBuyout
				end
				if not ps.minBuyout or buyout < ps.minBuyout then
					ps.minBuyout = buyout
				end
				if not ps.maxBuyout or buyout > ps.maxBuyout then
					ps.maxBuyout = buyout
				end
				if stackSize > ps.qtyMax then
					ps.qtyMax = stackSize
				end
				if stackSize > 1 then
					ps.stacksGt1 = ps.stacksGt1 + 1
				end
			end
		end
	end

	-- Class-batch queries: reject rows whose name matches none of the target
	-- items right here, before the expensive link fetch and parsing. The name
	-- comes free with GetAuctionItemInfo above.
	if private.classicNameFilter and not private.classicNameFilter[strlower(rawName)] then
		cs.nameReject = cs.nameReject + 1
		return true
	end

	-- 3.3.5: Фильтруем по поисковой строке прямо здесь, как в Auctionator (не добавляем в browseResults, если не совпадает)
	if private.query._str and private.query._str ~= "" then
		local nameLower = strlower(rawName)
		if private.query._exact then
			if nameLower ~= private.query._strLower then
				cs.nameSkip = cs.nameSkip + 1
				return true
			end
		else
			if not strfind(nameLower, private.query._strLower, 1, true) then
				cs.nameSkip = cs.nameSkip + 1
				return true
			end
		end
	end


	if not itemLink then
		cs.noLink = cs.noLink + 1
		return false
	end

	tPhase = debugprofilestop()
	local baseItemString = ItemString.Get(itemLink)
	cs.tParse = cs.tParse + (debugprofilestop() - tPhase)
	if not baseItemString then
		cs.badLink = cs.badLink + 1
		return false
	end

	-- getAll dumps the whole AH; skip items not in the requested set early so we don't
	-- spend cycles populating SubRows for 50k irrelevant lots.
	local items = private.query._items
	if next(items) and not items[baseItemString] then
		cs.earlyReject = cs.earlyReject + 1
		return true
	end
	if private.resolveSellers and (not seller or seller == "") then
		if not private.sellerWaitStart then
			private.sellerWaitStart = GetTime()
		end
		if GetTime() - private.sellerWaitStart < SELLER_WAIT_MAX_TIME then
			private.sellerWaitCounts[index] = (private.sellerWaitCounts[index] or 0) + 1
			return false
		end
		seller = "?"
	end
	tPhase = debugprofilestop()
	private.query:_ProcessBrowseResult(baseItemString, itemLink)
	private.query:_MarkDirtyRow(baseItemString)
	local row = private.query:_GetBrowseResults(baseItemString)
	local page = (private.query and private.query._page) or 0
	row:PopulateSubRows(private.browseId, index, itemLink, page)
	cs.tPopulate = cs.tPopulate + (debugprofilestop() - tPhase)
	cs.added = cs.added + 1
	-- Classic browse rows always have raw data for newly populated listings,
	-- so no need to scan all existing subRows on every auction index.
	return true
end

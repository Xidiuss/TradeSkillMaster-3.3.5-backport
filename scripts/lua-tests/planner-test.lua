local ctx = assert(_G.TSM_PLANNER_CTX)
local Query = assert(ctx.classes.AuctionQuery, "real Query.lua was not loaded")

local function NewQuery()
	return Query.Get()
end

ctx.test("planner metadata exposes exact kind and fallback parent", function()
	local parent = NewQuery():SetScanPlanKind("CATEGORY")
	local child = NewQuery():SetScanPlanKind("EXACT"):SetFallbackParent(parent)
	assert(parent:GetScanPlanKind() == "CATEGORY")
	assert(child:GetScanPlanKind() == "EXACT")
	assert(child:GetFallbackParent() == parent)
end)

ctx.test("browse order violations are routed through the persisted scan trace", function()
	TSM_SCAN_TRACE = true
	wipe(ctx.scanTraceMessages)
	local query = NewQuery():SetUsePriceSort(true)
	query._page = 2
	query:_RecordBrowseUnitPrice(100, 200)
	query:_RecordBrowseUnitPrice(90, 190)
	assert(#ctx.scanTraceMessages == 2)
	assert(string.find(ctx.scanTraceMessages[1], "BUYOUT order VIOLATED", 1, true))
	assert(string.find(ctx.scanTraceMessages[2], "UNIT price order VIOLATED", 1, true))
	assert(string.find(ctx.scanTraceMessages[1], "page 2", 1, true))
	TSM_SCAN_TRACE = false
end)

ctx.test("short final page records FULL", function()
	local query = NewQuery()
	ctx.SetPage(12, 112, "item:first", "item:last")
	assert(query:_BrowseIsDone() == true)
	assert(query:HasCompletedFullBrowse() == true)
	assert(query:HasEndedEarly() == false)
	assert(query:GetEndReason() == "FULL")
	assert(query:GetMaxTotalSeen() == 112)
	assert(query:GetPage() == 0)
end)

ctx.test("reliable page cap records FULL", function()
	local query = NewQuery()
	query._page = 1
	ctx.SetPage(50, 100, "item:first-2", "item:last-2")
	assert(query:_BrowseIsDone() == true)
	assert(query:HasCompletedFullBrowse() == true)
	assert(query:GetEndReason() == "FULL")
end)

ctx.test("done callback preserves COST_SWITCH reason", function()
	local query = NewQuery()
	query:SetIsBrowseDoneFunction(function()
		return true, "COST_SWITCH"
	end)
	ctx.SetPage(50, 500, "item:first-3", "item:last-3")
	assert(query:_BrowseIsDone() == true)
	assert(query:HasCompletedFullBrowse() == false)
	assert(query:HasEndedEarly() == true)
	assert(query:GetEndReason() == "COST_SWITCH")
end)

ctx.test("legacy boolean done callback records EARLY", function()
	local query = NewQuery()
	query:SetIsBrowseDoneFunction(function()
		return true
	end)
	ctx.SetPage(50, 500, "item:first-4", "item:last-4")
	assert(query:_BrowseIsDone() == true)
	assert(query:HasCompletedFullBrowse() == false)
	assert(query:HasEndedEarly() == true)
	assert(query:GetEndReason() == "EARLY")
end)

ctx.test("repeated full page records INCOMPLETE and never FULL", function()
	local query = NewQuery()
	ctx.SetPage(50, 0, "item:repeat-first", "item:repeat-last")
	assert(query:_BrowseIsDone() == false)
	query._page = 1
	assert(query:_BrowseIsDone() == true)
	assert(query:HasCompletedFullBrowse() == false)
	assert(query:HasEndedEarly() == true)
	assert(query:GetEndReason() == "INCOMPLETE")
end)

ctx.test("rechecking the same page does not look like a repeated next page", function()
	local query = NewQuery()
	ctx.SetPage(50, 0, "item:page-zero-first", "item:page-zero-last")
	assert(query:_BrowseIsDone() == false)
	query._page = 1
	ctx.SetPage(50, 0, "item:page-one-first", "item:page-one-last")
	assert(query:_BrowseIsDone() == false)
	assert(query:_BrowseIsDone() == false)
	assert(query:GetEndReason() == nil)
end)

ctx.test("starting a new browse resets terminal browse state", function()
	local query = NewQuery()
	ctx.SetPage(12, 12, "item:first-5", "item:last-5")
	assert(query:_BrowseIsDone() == true)
	query:Browse()
	assert(query:GetEndReason() == nil)
	assert(query:HasCompletedFullBrowse() == false)
	assert(query:HasEndedEarly() == false)
	assert(query:GetMaxTotalSeen() == 0)
	assert(query:GetPage() == 0)
end)

ctx.test("starting a new browse resets price ordering evidence", function()
	local query = NewQuery():SetUsePriceSort(true)
	query:_RecordBrowseUnitPrice(100, 200)
	query:_RecordBrowseUnitPrice(90, 190)
	assert(query:IsPriceSorted() == false)
	assert(query:IsBuyoutOrdered() == false)
	query:Browse()
	assert(query:IsPriceSorted() == true)
	assert(query:IsBuyoutOrdered() == true)
end)

print(string.format("Planner Query tests done: %d passed, %d failed", ctx.passed, ctx.failures))

local QueryUtil = assert(ctx.modules["AuctionScan.QueryUtil"], "real QueryUtil.lua was not loaded")

local function SetItem(itemString, name, classId)
	ctx.itemInfo[itemString] = {
		name = name,
		quality = 1,
		level = 1,
		classId = classId or 16,
		subClassId = 0,
	}
end

local function Generate(items)
	local copy = {}
	for i, itemString in ipairs(items) do
		copy[i] = itemString
	end
	local result = {}
	QueryUtil.GenerateThreaded(copy, function(query)
		tinsert(result, query)
	end)
	return result
end

local function QueryItems(query)
	local result = {}
	for itemString in query:ItemIterator() do
		tinsert(result, itemString)
	end
	sort(result)
	return result
end

local function Join(items)
	return table.concat(items, ",")
end

local function PlanSignature(queries)
	local indexes = {}
	for index, query in ipairs(queries) do
		indexes[query] = index
	end
	local result = {}
	for index, query in ipairs(queries) do
		local parent = query:GetFallbackParent()
		result[index] = table.concat({
			query:GetScanPlanKind() or "-",
			query._str,
			query._exact and "exact" or "partial",
			tostring(query._class),
			Join(QueryItems(query)),
			parent and tostring(indexes[parent]) or "-",
		}, "|")
	end
	return table.concat(result, "\n")
end

local function SetDisjointFixture()
	SetItem("i:1", "Alphaaa One", 16)
	SetItem("i:2", "Alphaaa Two", 16)
	SetItem("i:3", "Betabbb One", 16)
	SetItem("i:4", "Betabbb Two", 16)
	SetItem("i:5", "Solitary", 16)
end

ctx.test("NARROW groups are deterministic, disjoint, and depth-first", function()
	SetDisjointFixture()
	local first = Generate({ "i:4", "i:2", "i:5", "i:1", "i:3" })
	local second = Generate({ "i:3", "i:1", "i:5", "i:2", "i:4" })
	assert(PlanSignature(first) == PlanSignature(second))
	assert(#first == 7)
	assert(first[1]:GetScanPlanKind() == "NARROW" and first[1]._str == "alphaaa" and first[1]._class == 16)
	assert(Join(QueryItems(first[1])) == "i:1,i:2")
	assert(first[2]:GetScanPlanKind() == "EXACT" and first[2]:GetFallbackParent() == first[1] and first[2]._exact)
	assert(first[3]:GetScanPlanKind() == "EXACT" and first[3]:GetFallbackParent() == first[1] and first[3]._exact)
	assert(first[4]:GetScanPlanKind() == "NARROW" and first[4]._str == "betabbb" and first[4]._class == 16)
	assert(first[5]:GetFallbackParent() == first[4] and first[6]:GetFallbackParent() == first[4])
	assert(first[7]:GetScanPlanKind() == "EXACT" and first[7]:GetFallbackParent() == nil)
	assert(Join(QueryItems(first[7])) == "i:5")

	local assigned = {}
	for _, query in ipairs(first) do
		if query:GetFallbackParent() == nil then
			for _, itemString in ipairs(QueryItems(query)) do
				assert(not assigned[itemString])
				assigned[itemString] = true
			end
		end
	end
	assert(assigned["i:1"] and assigned["i:2"] and assigned["i:3"] and assigned["i:4"] and assigned["i:5"])
end)

local function SetUniqueFixture(count, prefix)
	local items = {}
	for index = 1, count do
		local itemString = "i:" .. tostring(100 + index)
		SetItem(itemString, (prefix or "TargetName") .. tostring(index), 16)
		items[index] = itemString
	end
	return items
end

ctx.test("12 targets use NARROW or EXACT without CATEGORY", function()
	local queries = Generate(SetUniqueFixture(12, "TwelveName"))
	assert(#queries == 12)
	for _, query in ipairs(queries) do
		assert(query:GetScanPlanKind() == "EXACT")
		assert(query:GetFallbackParent() == nil)
	end
end)

ctx.test("13 targets prepend CATEGORY and parent every fallback root", function()
	local queries = Generate(SetUniqueFixture(13, "ThirteenName"))
	local category = queries[1]
	assert(#queries == 14)
	assert(category:GetScanPlanKind() == "CATEGORY")
	assert(category._str == "" and category._class == 16)
	assert(Join(QueryItems(category)) == Join(SetUniqueFixture(13, "ThirteenName")))
	for index = 2, #queries do
		assert(queries[index]:GetScanPlanKind() == "EXACT")
		assert(queries[index]:GetFallbackParent() == category)
	end
end)

ctx.test("CATEGORY continues on equal estimated cost", function()
	local category = Generate(SetUniqueFixture(13, "CategoryTie"))[1]
	ctx.SetPage(50, 700, "item:category-tie-first", "item:category-tie-last")
	assert(category:_BrowseIsDone() == false)
	assert(category:GetEndReason() == nil)
end)

ctx.test("CATEGORY switches only when fallback is strictly cheaper", function()
	local category = Generate(SetUniqueFixture(13, "CategorySwitch"))[1]
	ctx.SetPage(50, 750, "item:category-switch-first", "item:category-switch-last")
	assert(category:_BrowseIsDone() == true)
	assert(category:GetEndReason() == "COST_SWITCH")
end)

local function SetNestedFallbackFixture(count, sharedWord, firstItemId)
	local items = {}
	for index = 1, count do
		local itemString = "i:" .. tostring(firstItemId + index)
		SetItem(itemString, sharedWord .. " Variant" .. tostring(index), 16)
		items[index] = itemString
	end
	return items
end

ctx.test("CATEGORY counts NARROW and all EXACT descendants when costs tie", function()
	local queries = Generate(SetNestedFallbackFixture(13, "Nestedcost", 400))
	local category = queries[1]
	assert(#queries == 15)
	assert(category:GetScanPlanKind() == "CATEGORY")
	assert(queries[2]:GetScanPlanKind() == "NARROW" and queries[2]:GetFallbackParent() == category)
	ctx.SetPage(50, 750, "item:nested-tie-first", "item:nested-tie-last")
	assert(category:_BrowseIsDone() == false)
	assert(category:GetEndReason() == nil)
end)

ctx.test("CATEGORY switches when a complete nested fallback is strictly cheaper", function()
	local category = Generate(SetNestedFallbackFixture(13, "Nestedswitch", 500))[1]
	ctx.SetPage(50, 800, "item:nested-switch-first", "item:nested-switch-last")
	assert(category:_BrowseIsDone() == true)
	assert(category:GetEndReason() == "COST_SWITCH")
end)

ctx.test("NARROW continues on equal exact-fallback cost", function()
	SetItem("i:301", "Sharedword One", 16)
	SetItem("i:302", "Sharedword Two", 16)
	local narrow = Generate({ "i:302", "i:301" })[1]
	assert(narrow:GetScanPlanKind() == "NARROW")
	ctx.SetPage(50, 150, "item:narrow-tie-first", "item:narrow-tie-last")
	assert(narrow:_BrowseIsDone() == false)
	assert(narrow:GetEndReason() == nil)
end)

ctx.test("NARROW switches when exact fallbacks are strictly cheaper", function()
	SetItem("i:311", "Switchword One", 16)
	SetItem("i:312", "Switchword Two", 16)
	local narrow = Generate({ "i:312", "i:311" })[1]
	ctx.SetPage(50, 200, "item:narrow-switch-first", "item:narrow-switch-last")
	assert(narrow:_BrowseIsDone() == true)
	assert(narrow:GetEndReason() == "COST_SWITCH")
end)

print(string.format("Planner QueryUtil tests done: %d passed, %d failed", ctx.passed, ctx.failures))

local ScanManager = assert(ctx.classes.AuctionScanManager, "real ScanManager.lua was not loaded")

local function NewPlannedQuery(kind, parent)
	local query = NewQuery():SetScanPlanKind(kind)
	if parent then
		query:SetFallbackParent(parent)
	end
	return query
end

local function RunManager(queries, outcomes)
	local manager = ScanManager.Get()
	local processed = {}
	local consumed = {}
	for _, query in ipairs(queries) do
		manager:_AddQuery(query)
	end
	manager._ProcessQuery = function(_, query)
		tinsert(processed, query)
		local outcome = assert(outcomes[query])
		if not outcome.success then
			return false, 0
		end
		query:_SetBrowseEndReason(outcome.reason)
		return true, outcome.numNewResults or 1
	end
	manager:SetScript("OnQueryDone", function(_, query)
		tinsert(consumed, query)
	end)
	local success = manager:ScanQueriesThreaded()
	return manager, success, processed, consumed
end

ctx.test("FULL ancestor skips the entire descendant chain", function()
	local category = NewPlannedQuery("CATEGORY")
	local narrow = NewPlannedQuery("NARROW", category)
	local exact = NewPlannedQuery("EXACT", narrow)
	local manager, success, processed, consumed = RunManager(
		{ category, narrow, exact },
		{
			[category] = { success = true, reason = "FULL" },
			[narrow] = { success = true, reason = "FULL" },
			[exact] = { success = true, reason = "FULL" },
		}
	)
	assert(success == true)
	assert(#processed == 1 and processed[1] == category)
	assert(#consumed == 1 and consumed[1] == category)
	assert(manager._queriesScanned == 3)
end)

ctx.test("COST_SWITCH runs fallback children without consuming partial parent", function()
	local category = NewPlannedQuery("CATEGORY")
	local exact1 = NewPlannedQuery("EXACT", category)
	local exact2 = NewPlannedQuery("EXACT", category)
	local _, success, processed, consumed = RunManager(
		{ category, exact1, exact2 },
		{
			[category] = { success = true, reason = "COST_SWITCH" },
			[exact1] = { success = true, reason = "FULL" },
			[exact2] = { success = true, reason = "FULL" },
		}
	)
	assert(success == true)
	assert(#processed == 3)
	assert(#consumed == 2 and consumed[1] == exact1 and consumed[2] == exact2)
end)

ctx.test("FULL query invokes the consumer exactly once", function()
	local exact = NewPlannedQuery("EXACT")
	local _, success, processed, consumed = RunManager(
		{ exact },
		{ [exact] = { success = true, reason = "FULL" } }
	)
	assert(success == true)
	assert(#processed == 1)
	assert(#consumed == 1 and consumed[1] == exact)
end)

ctx.test("planned EXACT EARLY fails without consuming partial results", function()
	local exact = NewPlannedQuery("EXACT")
	local _, success, processed, consumed = RunManager(
		{ exact },
		{ [exact] = { success = true, reason = "EARLY" } }
	)
	assert(success == false)
	assert(#processed == 1)
	assert(#consumed == 0)
end)

ctx.test("unplanned EARLY retains legacy consumer behavior", function()
	local query = NewQuery()
	local _, success, processed, consumed = RunManager(
		{ query },
		{ [query] = { success = true, reason = "EARLY" } }
	)
	assert(success == true)
	assert(#processed == 1)
	assert(#consumed == 1 and consumed[1] == query)
end)

ctx.test("unplanned INCOMPLETE fails without consuming partial results", function()
	local query = NewQuery()
	local _, success, processed, consumed = RunManager(
		{ query },
		{ [query] = { success = true, reason = "INCOMPLETE" } }
	)
	assert(success == false)
	assert(#processed == 1)
	assert(#consumed == 0)
end)

ctx.test("INCOMPLETE parent runs its fallback", function()
	local narrow = NewPlannedQuery("NARROW")
	local exact = NewPlannedQuery("EXACT", narrow)
	local _, success, processed, consumed = RunManager(
		{ narrow, exact },
		{
			[narrow] = { success = true, reason = "INCOMPLETE" },
			[exact] = { success = true, reason = "FULL" },
		}
	)
	assert(success == true)
	assert(#processed == 2)
	assert(#consumed == 1 and consumed[1] == exact)
end)

ctx.test("INCOMPLETE exact leaf fails the scan", function()
	local exact = NewPlannedQuery("EXACT")
	local _, success, processed, consumed = RunManager(
		{ exact },
		{ [exact] = { success = true, reason = "INCOMPLETE" } }
	)
	assert(success == false)
	assert(#processed == 1)
	assert(#consumed == 0)
end)

ctx.test("browse error stops without consuming or treating partial data as FULL", function()
	local category = NewPlannedQuery("CATEGORY")
	local exact = NewPlannedQuery("EXACT", category)
	local _, success, processed, consumed = RunManager(
		{ category, exact },
		{
			[category] = { success = false, reason = "FULL" },
			[exact] = { success = true, reason = "FULL" },
		}
	)
	assert(success == false)
	assert(#processed == 1 and processed[1] == category)
	assert(#consumed == 0)
	assert(category:HasCompletedFullBrowse() == false)
end)

print(string.format("Planner ScanManager tests done: %d passed, %d failed", ctx.passed, ctx.failures))

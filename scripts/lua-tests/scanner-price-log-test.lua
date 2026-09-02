local passed, failures = 0, 0

local function test(name, func)
	local ok, err = pcall(func)
	if ok then
		passed = passed + 1
	else
		failures = failures + 1
		print("FAIL: "..name.." -> "..tostring(err))
	end
end

local ctx = assert(SCANNER_PRICE_LOG_CTX)
local private = assert(load(SCANNER_SRC.."\nreturn private", "Scanner.lua"))(nil, ctx.addonTable)

local function NewQuery(kind, text)
	local items = { "i:42453" }
	local query = {
		_str = text,
		_strLower = string.lower(text),
		_exact = kind == "EXACT",
		_items = { ["i:42453"] = true },
		_page = 3,
	}
	function query:ItemIterator()
		local index = 0
		return function()
			index = index + 1
			return items[index]
		end
	end
	function query:GetScanPlanKind() return kind end
	function query:_RecordBrowseUnitPrice() end
	function query:_GetBrowseResults()
		return { GetNumSubRows = function() return 1 end }
	end
	function query:IsBuyoutOrdered() return true end
	function query:IsPriceSorted() return true end
	return query
end

local function StartQuery(query)
	private.query = query
	private.resolveSellers = true
	private.classicNameFilter = private.BuildClassicNameFilter(query)
	private.classicTraceNameFilter = private.BuildClassicTraceNameFilter(query)
	wipe(private.tracedRowIndexes)
	wipe(ctx.rawRows)
	private.scanTrace.pageStats = nil
end

test("EXACT raw logging records a target row once before pending seller retry", function()
	local query = NewQuery("EXACT", "Glyph Target")
	StartQuery(query)
	ctx.rows[1] = {
		rawName = "Glyph Target", itemLink = "item:42453:0:0:0:0:0:0:0",
		stackSize = 2, timeLeft = 4, buyout = 200, seller = nil,
	}
	assert(private.ProcessBrowseResultClassic(1) == false)
	assert(private.ProcessBrowseResultClassic(1) == false)
	assert(#ctx.rawRows == 1)
	local raw = ctx.rawRows[1]
	assert(raw.queryKind == "EXACT" and raw.queryText == "Glyph Target")
	assert(raw.page == 3 and raw.rowIndex == 1)
	assert(raw.rawName == "Glyph Target" and raw.itemLink == ctx.rows[1].itemLink)
	assert(raw.stackSize == 2 and raw.stackBuyout == 200 and raw.unitBuyout == 100)
	assert(raw.timeLeft == 4 and raw.hasItemLink == true)
end)

test("CATEGORY raw logging includes target without link and excludes unrelated names", function()
	local query = NewQuery("CATEGORY", "")
	StartQuery(query)
	ctx.rows[1] = {
		rawName = "Glyph Target", itemLink = nil,
		stackSize = 1, timeLeft = 2, buyout = 75, seller = "SellerA",
	}
	ctx.rows[2] = {
		rawName = "Unrelated Item", itemLink = "item:999:0:0:0:0:0:0:0",
		stackSize = 1, timeLeft = 3, buyout = 50, seller = "SellerB",
	}
	assert(private.ProcessBrowseResultClassic(1) == false)
	assert(private.ProcessBrowseResultClassic(2) == true)
	assert(#ctx.rawRows == 1)
	local raw = ctx.rawRows[1]
	assert(raw.queryKind == "CATEGORY" and raw.queryText == "")
	assert(raw.rawName == "Glyph Target" and raw.hasItemLink == false)
	assert(raw.seller == "SellerA" and raw.unitBuyout == 75)
end)

test("page and query summaries are routed through the persisted scan trace", function()
	local query = NewQuery("CATEGORY", "")
	StartQuery(query)
	wipe(ctx.traceMessages)
	private.scanTrace.pageStats = {
		page = 3, rows = 2, req = 0.25,
		minBuyout = 75, maxBuyout = 200, minUnit = 75, maxUnit = 100,
		qtyMax = 2, stacksGt1 = 1,
	}
	private.scanTrace.targetsTotal = 1
	private.scanTrace.targetsSeen = 0
	private.ScanTraceFinishPage()
	assert(#ctx.traceMessages == 1)
	assert(string.find(ctx.traceMessages[1], "page=3 rows=2", 1, true))

	private.scanTrace.t0 = 100
	private.scanTrace.tSend = 100.1
	private.scanTrace.tResp = 100.2
	private.scanTrace.str = ""
	private.scanTrace.pagesCount = 1
	private.scanTrace.finalBuyoutOrder = true
	private.scanTrace.finalUnitOrder = true
	private.scanTrace.finalEndedEarly = false
	private.scanTrace.finalEndReason = "FULL"
	private.requestResult = true
	private.requestFuture = {
		IsReady = function() return false end,
		IsDone = function() return false end,
		Done = function() end,
	}
	private.RequestDoneHandler()
	assert(#ctx.traceMessages == 2)
	assert(string.find(ctx.traceMessages[2], 'q=""', 1, true))
	assert(string.find(ctx.traceMessages[2], "reason=FULL", 1, true))
end)

return passed, failures

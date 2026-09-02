local passed, failures = 0, 0
local realPrint = print
local printed = {}

function print(message)
	table.insert(printed, tostring(message))
end

local function test(name, func)
	local ok, err = pcall(func)
	if ok then
		passed = passed + 1
	else
		failures = failures + 1
		realPrint("FAIL: "..name.." -> "..tostring(err))
	end
end

local now = 1700000000
function time()
	now = now + 1
	return now
end

assert(load(TSM_POST_SCAN_ADDON_SRC, "TSM_PostScan/Core.lua"))()
assert(load(TSM_CANCEL_SCAN_ADDON_SRC, "TSM_CancelScan/Core.lua"))()

local chunk = assert(load(TSM_PRICE_LOG_SRC, "TSMDebug.lua"))
chunk()

local function DecodeCompactRow(columns, encoded)
	assert(type(columns) == "string" and type(encoded) == "string")
	local values, current, escaped = {}, "", false
	for index = 1, #encoded do
		local char = string.sub(encoded, index, index)
		if escaped then
			if char == "p" then
				current = current.."|"
			elseif char == "n" then
				current = current.."\n"
			elseif char == "r" then
				current = current.."\r"
			else
				current = current..char
			end
			escaped = false
		elseif char == "\\" then
			escaped = true
		elseif char == "|" then
			table.insert(values, current)
			current = ""
		else
			current = current..char
		end
	end
	assert(not escaped)
	table.insert(values, current)

	local result, valueIndex = {}, 1
	for column in string.gmatch(columns, "[^|]+") do
		result[column] = values[valueIndex]
		valueIndex = valueIndex + 1
	end
	return result
end

test("disabled trace has zero logger side effects", function()
	TSM_SCAN_TRACE = false
	TSMPostScanLogDB, TSMCancelScanLogDB, TSMPriceLogDB = nil, nil, nil
	TSMDBG.PriceLogBegin("POST", 13)
	TSMDBG.PriceLogTrace("hidden")
	TSMDBG.PriceLogRawAuction({ rawName = "Glyph" })
	TSMDBG.PriceLogDecision("POST", { itemString = "i:43533" })
	TSMDBG.PriceLogEnd("POST", true)
	assert(TSMPostScanLogDB == nil and TSMCancelScanLogDB == nil and TSMPriceLogDB == nil)
	assert(#printed == 0)
end)

test("reset creates two independent scan databases", function()
	TSM_SCAN_TRACE = true
	TSMPostScanLogDB, TSMCancelScanLogDB, TSMPriceLogDB = nil, nil, nil
	TSMDBG.PriceLogReset()
	assert(TSMPostScanLogDB.version == 1 and #TSMPostScanLogDB.runs == 0)
	assert(TSMCancelScanLogDB.version == 1 and #TSMCancelScanLogDB.runs == 0)
	assert(TSMPostScanLogDB ~= TSMCancelScanLogDB)
	assert(TSMPriceLogDB == nil)
end)

test("POST decisions raw rows and trace never enter CANCEL database", function()
	TSMDBG.PriceLogBegin("POST", 47)
	TSMDBG.PriceLogTrace("[TSM ScanTrace] page=0 rows=50")
	TSMDBG.PriceLogRawAuction({
		queryKind = "CATEGORY", queryText = "", page = 0, rowIndex = 3,
		rawName = "Glyph|Raw\\Name\nLine", itemLink = "item:42453:0:0:0:0:0:0:0",
		stackSize = 2, stackBuyout = 1598276, unitBuyout = 799138,
		seller = "Tester", timeLeft = 4, hasItemLink = true,
	})
	TSMDBG.PriceLogDecision("POST", {
		itemString = "i:42453", itemId = 42453, itemName = "Glyph of Incinerate",
		operation = "Glyph|Post\\One\nLine", marketBuyout = 799138, undercut = 500,
		proposedBuyout = 798638, decision = "POSTING.UNDERCUT",
		queryKind = "CATEGORY", queryEndReason = "FULL",
	})
	TSMDBG.PriceLogEnd("POST", true)

	assert(#TSMPostScanLogDB.runs == 1 and #TSMCancelScanLogDB.runs == 0)
	local run = TSMPostScanLogDB.runs[1]
	assert(run.scanType == "POST" and run.targetCount == 47)
	assert(run.trace[1] == "[TSM ScanTrace] page=0 rows=50")
	assert(printed[#printed] == run.trace[1])
	assert(run.success == true and run.decisionCount == 1 and run.rawCount == 1)
	assert(run.endedAt > run.startedAt)
	local decision = DecodeCompactRow(run.decisionColumns, run.decisionRows[1])
	assert(decision.operation == "Glyph|Post\\One\nLine")
	assert(decision.marketBuyout == "799138" and decision.proposedBuyout == "798638")
	local raw = DecodeCompactRow(run.rawColumns, run.rawRows[1])
	assert(raw.rawName == "Glyph|Raw\\Name\nLine")
	assert(raw.stackBuyout == "1598276" and raw.unitBuyout == "799138")
	assert(raw.hasItemLink == "true")
end)

test("two CANCEL scans create two CANCEL runs", function()
	for index = 1, 2 do
		TSMDBG.PriceLogBegin("CANCEL", 47)
		TSMDBG.PriceLogDecision("CANCEL", {
			itemString = "i:43533", listedBuyout = 14000 + index,
			marketBuyout = 12000, decision = "AUCTIONING_OPERATION_RESULT.CANCELING.UNDERCUT",
		})
		TSMDBG.PriceLogEnd("CANCEL", index == 2)
	end
	assert(#TSMPostScanLogDB.runs == 1)
	assert(#TSMCancelScanLogDB.runs == 2)
	assert(TSMCancelScanLogDB.runs[1].success == false)
	assert(TSMCancelScanLogDB.runs[2].success == true)
	local decoded = DecodeCompactRow(
		TSMCancelScanLogDB.runs[2].decisionColumns,
		TSMCancelScanLogDB.runs[2].decisionRows[1]
	)
	assert(decoded.listedBuyout == "14002")
end)

test("missing module helper reports exact companion names", function()
	assert(TSMDBG.GetMissingPriceLogModules() == nil)
	TSM_POST_SCAN_LOGGER_LOADED = nil
	assert(TSMDBG.GetMissingPriceLogModules() == "TSM_PostScan")
	TSM_CANCEL_SCAN_LOGGER_LOADED = nil
	assert(TSMDBG.GetMissingPriceLogModules() == "TSM_PostScan, TSM_CancelScan")
	TSM_POST_SCAN_LOGGER_LOADED = true
	assert(TSMDBG.GetMissingPriceLogModules() == "TSM_CancelScan")
	TSM_CANCEL_SCAN_LOGGER_LOADED = true
end)

return passed, failures

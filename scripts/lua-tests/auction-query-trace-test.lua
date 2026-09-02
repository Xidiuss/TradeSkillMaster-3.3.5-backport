local passed = 0
local failures = 0

local function Check(condition, message)
	if condition then
		passed = passed + 1
	else
		failures = failures + 1
		print("FAIL: "..message)
	end
end

local function GetOnlyRun(database)
	return database and database.runs and database.runs[1]
end

local function RunProviderCase(providerName, glyphClassId)
	local context = NewWrapperContext(glyphClassId)
	local postTrace = "[TSM ScanTrace] SEND q=\"\" page=0 classId="..glyphClassId.." classIndex=5"
	local cancelTrace = "[TSM ScanTrace] SEND q=\"Glyph\" page=1 classId="..glyphClassId.." classIndex=5"

	TSMDBG.PriceLogBegin("POST", 1)
	local future = context.module.SendQuery("", glyphClassId, nil, nil, nil, nil, 0, nil, nil, nil, nil, nil, 0, nil)
	TSMDBG.PriceLogEnd("POST", true)
	local postRun = GetOnlyRun(TSMPostScanLogDB)
	local postCall = context.nativeCalls[1]

	Check(future ~= nil, providerName.." query did not return its real APIWrapper future")
	Check(postCall and postCall.count == 10, providerName.." native query did not preserve all 10 arguments")
	Check(postCall and postCall[1] == "" and postCall[5] == 5 and postCall[7] == 0, providerName.." native POST arguments are wrong")
	Check(context.sequence[1] == "TRACE" and context.sequence[2] == "NATIVE", providerName.." POST trace is not immediately before the native call")
	Check(postRun and #postRun.trace == 1 and postRun.trace[1] == postTrace, providerName.." POST trace was not persisted in TSMPostScanLogDB")

	TSMDBG.PriceLogBegin("CANCEL", 1)
	context.module.SendQuery("Glyph", glyphClassId, nil, nil, nil, nil, 0, nil, nil, nil, nil, nil, 1, nil)
	TSMDBG.PriceLogEnd("CANCEL", true)
	local cancelRun = GetOnlyRun(TSMCancelScanLogDB)
	local cancelCall = context.nativeCalls[2]

	Check(cancelCall and cancelCall.count == 10, providerName.." native CANCEL query did not preserve all 10 arguments")
	Check(cancelCall and cancelCall[1] == "Glyph" and cancelCall[5] == 5 and cancelCall[7] == 1, providerName.." native CANCEL arguments are wrong")
	Check(context.sequence[3] == "TRACE" and context.sequence[4] == "NATIVE", providerName.." CANCEL trace is not immediately before the native call")
	Check(cancelRun and #cancelRun.trace == 1 and cancelRun.trace[1] == cancelTrace, providerName.." CANCEL trace was not persisted in TSMCancelScanLogDB")

	local nativeCountBeforeDisabledQuery = #context.nativeCalls
	local sequenceCountBeforeDisabledQuery = #context.sequence
	_G.TSM_SCAN_TRACE = false
	TSMDBG.PriceLogBegin("POST", 1)
	context.module.SendQuery("Disabled", glyphClassId, nil, nil, nil, nil, 0, nil, nil, nil, nil, nil, 2, nil)
	Check(#context.nativeCalls == nativeCountBeforeDisabledQuery + 1, providerName.." disabled trace changed native query behavior")
	Check(#context.sequence == sequenceCountBeforeDisabledQuery + 1 and context.sequence[#context.sequence] == "NATIVE", providerName.." disabled trace still emitted TRACE")
	Check(#TSMPostScanLogDB.runs == 1 and #TSMCancelScanLogDB.runs == 1, providerName.." disabled trace created a persisted run")
end

local function RunRejectedStartCase()
	local context = NewWrapperContext(5)
	context.SetNativeHooksEnabled(false)
	TSMDBG.PriceLogBegin("POST", 1)
	context.module.SendQuery("First", 5, nil, nil, nil, nil, 0, nil, nil, nil, nil, nil, 0, nil)
	context.module.SendQuery("Rejected", 5, nil, nil, nil, nil, 0, nil, nil, nil, nil, nil, 1, nil)
	TSMDBG.PriceLogEnd("POST", true)
	local postRun = GetOnlyRun(TSMPostScanLogDB)

	Check(#context.nativeCalls == 1, "busy APIWrapper unexpectedly reached QueryAuctionItems twice")
	Check(postRun and #postRun.trace == 1, "rejected APIWrapper.Start emitted a false SEND trace")
end

RunProviderCase("external provider", 5)
RunProviderCase("bundled provider", 16)
RunRejectedStartCase()

return passed, failures

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

TSM_SCAN_TRACE = true
TSMDBG.PriceLogReset()

test("real PostScan decision records market, operation, proposal, and query completion", function()
	local private = assert(load(POST_SCAN_SRC.."\nreturn private", "PostScan.lua"))(nil, AUCTION_PRICE_LOG_CTX.addonTable)
	private.queueDB = AUCTION_PRICE_LOG_CTX.NewQueueDB("POST")
	private.settings = { matchWhitelist = false }
	TSMDBG.PriceLogBegin("POST", 13)
	local reason = private.GeneratePosts(
		"i:43533",
		"Glyph Post",
		AUCTION_PRICE_LOG_CTX.operationSettings,
		1,
		{},
		AUCTION_PRICE_LOG_CTX.NewScanQuery("CATEGORY", "FULL")
	)
	TSMDBG.PriceLogEnd("POST", true)

	assert(reason == AUCTION_PRICE_LOG_CTX.addonTable.LibTSMSystem:Include("AuctioningOperation").RESULT.POSTING.UNDERCUT)
	assert(AUCTION_PRICE_LOG_CTX.queuedPosts == 1)
	local run = TSMPostScanLogDB.runs[1]
	local row = AUCTION_PRICE_LOG_CTX.DecodePriceLogRow(run.decisionColumns, run.decisionRows[1])
	assert(#TSMCancelScanLogDB.runs == 0)
	assert(row.itemString == "i:43533" and row.itemId == "43533")
	assert(row.marketBuyout == "12345" and row.proposedBuyout == "12344")
	assert(row.minPrice == "8000" and row.normalPrice == "20000" and row.maxPrice == "50000" and row.undercut == "1")
	assert(row.queryKind == "CATEGORY" and row.queryEndReason == "FULL")
	assert(row.decision == "AUCTIONING_OPERATION_RESULT.POSTING.UNDERCUT")
end)

test("PostScan early NOT_ENOUGH result is stored as a decision, not a market price", function()
	local private = assert(load(POST_SCAN_SRC.."\nreturn private", "PostScan.lua"))(nil, AUCTION_PRICE_LOG_CTX.addonTable)
	private.queueDB = AUCTION_PRICE_LOG_CTX.NewQueueDB("POST")
	private.settings = { matchWhitelist = false }
	local operation = AUCTION_PRICE_LOG_CTX.addonTable.LibTSMSystem:Include("AuctioningOperation")
	local originalGetPostQuantities = operation.GetPostQuantities
	operation.GetPostQuantities = function() return nil end

	TSMDBG.PriceLogBegin("POST", 1)
	private.GeneratePosts(
		"i:43533",
		"Glyph Post",
		AUCTION_PRICE_LOG_CTX.operationSettings,
		0,
		{},
		AUCTION_PRICE_LOG_CTX.NewScanQuery("EXACT", "FULL")
	)
	TSMDBG.PriceLogEnd("POST", true)
	operation.GetPostQuantities = originalGetPostQuantities

	local run = TSMPostScanLogDB.runs[#TSMPostScanLogDB.runs]
	local row = AUCTION_PRICE_LOG_CTX.DecodePriceLogRow(run.decisionColumns, run.decisionRows[1])
	assert(row.decision == "AUCTIONING_OPERATION_RESULT.NOT_POSTING.NOT_ENOUGH")
	assert(row.marketBid == nil and row.marketBuyout == nil)
	assert(row.proposedBid == nil and row.proposedBuyout == nil)
end)

test("real CancelScan decision records listed price, market price, and cancel reason", function()
	local private = assert(load(CANCEL_SCAN_SRC.."\nreturn private", "CancelScan.lua"))(nil, AUCTION_PRICE_LOG_CTX.addonTable)
	private.queueDB = AUCTION_PRICE_LOG_CTX.NewQueueDB("CANCEL")
	TSMDBG.PriceLogBegin("CANCEL", 1)
	local handled, reason = private.GenerateCancel(
		AUCTION_PRICE_LOG_CTX.listedAuction,
		"i:43533",
		"Glyph Cancel",
		AUCTION_PRICE_LOG_CTX.operationSettings,
		{},
		AUCTION_PRICE_LOG_CTX.NewScanQuery("EXACT", "FULL")
	)
	TSMDBG.PriceLogEnd("CANCEL", true)

	assert(handled == true and tostring(reason) == "AUCTIONING_OPERATION_RESULT.CANCELING.UNDERCUT")
	assert(AUCTION_PRICE_LOG_CTX.queuedCancels == 1)
	local run = TSMCancelScanLogDB.runs[#TSMCancelScanLogDB.runs]
	local row = AUCTION_PRICE_LOG_CTX.DecodePriceLogRow(run.decisionColumns, run.decisionRows[1])
	assert(row.listedBuyout == "14000" and row.marketBuyout == "12345")
	assert(row.playerLowestBuyout == "14000" and row.secondLowestBuyout == "15000")
	assert(row.cancelRepostThreshold == "2500" and row.hasBid == "false")
	assert(row.queryKind == "EXACT" and row.queryEndReason == "FULL")
	assert(row.decision == "AUCTIONING_OPERATION_RESULT.CANCELING.UNDERCUT")
end)

return passed, failures

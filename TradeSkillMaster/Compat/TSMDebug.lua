-- ============================================================================
--                                TradeSkillMaster                              --
-- Lightweight debug shim and opt-in auction scan logger.
--
-- With scantrace disabled this module does not create databases or retain scan
-- data. With scantrace enabled it routes POST and CANCEL runs into SavedVariables
-- owned by the separate TSM_PostScan and TSM_CancelScan companion addons.
-- ============================================================================

local function noop() end

local DB_VERSION = 1
local currentPriceLogRun = nil

local DB_GLOBAL_BY_SCAN_TYPE = {
	POST = "TSMPostScanLogDB",
	CANCEL = "TSMCancelScanLogDB",
}

local DECISION_COLUMNS = {
	POST = {
		"itemString", "itemId", "itemName", "operation",
		"marketBid", "marketBuyout", "marketSeller",
		"minPrice", "normalPrice", "maxPrice", "undercut",
		"proposedBid", "proposedBuyout", "decision",
		"queryKind", "queryEndReason",
	},
	CANCEL = {
		"itemString", "itemId", "itemName", "operation",
		"marketBid", "marketBuyout", "marketSeller",
		"listedBid", "listedBuyout", "auctionId", "hasBid",
		"minPrice", "normalPrice", "maxPrice", "undercut", "cancelRepostThreshold",
		"playerLowestBuyout", "secondLowestBuyout", "handled", "decision",
		"queryKind", "queryEndReason",
	},
}

local RAW_COLUMNS = {
	"queryKind", "queryText", "page", "rowIndex", "rawName", "itemLink",
	"stackSize", "stackBuyout", "unitBuyout", "seller", "timeLeft", "hasItemLink",
}

local function EncodeValue(value)
	if value == nil then
		return ""
	end
	return tostring(value)
		:gsub("\\", "\\\\")
		:gsub("|", "\\p")
		:gsub("\r", "\\r")
		:gsub("\n", "\\n")
end

local function EncodeRow(columns, values)
	local row = {}
	for index, key in ipairs(columns) do
		row[index] = EncodeValue(values[key])
	end
	return table.concat(row, "|")
end

local function NewDatabase()
	return {
		version = DB_VERSION,
		createdAt = time(),
		runs = {},
	}
end

local function GetDatabase(scanType, create)
	local globalName = DB_GLOBAL_BY_SCAN_TYPE[scanType]
	if not globalName then
		return nil
	end
	local database = _G[globalName]
	if create and (type(database) ~= "table" or database.version ~= DB_VERSION or type(database.runs) ~= "table") then
		database = NewDatabase()
		_G[globalName] = database
	end
	return database
end

local function PriceLogReset()
	for _, globalName in pairs(DB_GLOBAL_BY_SCAN_TYPE) do
		_G[globalName] = NewDatabase()
	end
	currentPriceLogRun = nil
end

local function PriceLogBegin(scanType, targetCount)
	if not _G.TSM_SCAN_TRACE then
		return
	end
	local columns = DECISION_COLUMNS[scanType]
	local database = GetDatabase(scanType, true)
	if not columns or not database then
		return
	end
	currentPriceLogRun = {
		scanType = scanType,
		targetCount = targetCount,
		startedAt = time(),
		trace = {},
		rawColumns = table.concat(RAW_COLUMNS, "|"),
		rawRows = {},
		decisionColumns = table.concat(columns, "|"),
		decisionRows = {},
	}
	table.insert(database.runs, currentPriceLogRun)
end

local function PriceLogDecision(scanType, values)
	if not _G.TSM_SCAN_TRACE or not currentPriceLogRun or currentPriceLogRun.scanType ~= scanType then
		return
	end
	table.insert(currentPriceLogRun.decisionRows, EncodeRow(DECISION_COLUMNS[scanType], values))
end

local function PriceLogRawAuction(values)
	if not _G.TSM_SCAN_TRACE or not currentPriceLogRun then
		return
	end
	table.insert(currentPriceLogRun.rawRows, EncodeRow(RAW_COLUMNS, values))
end

local function PriceLogTrace(message)
	if not _G.TSM_SCAN_TRACE then
		return
	end
	message = tostring(message)
	print(message)
	if currentPriceLogRun then
		table.insert(currentPriceLogRun.trace, message)
	end
end

local function PriceLogEnd(scanType, success)
	if not _G.TSM_SCAN_TRACE or not currentPriceLogRun or currentPriceLogRun.scanType ~= scanType then
		return
	end
	currentPriceLogRun.success = success and true or false
	currentPriceLogRun.decisionCount = #currentPriceLogRun.decisionRows
	currentPriceLogRun.rawCount = #currentPriceLogRun.rawRows
	currentPriceLogRun.endedAt = time()
	currentPriceLogRun = nil
end

local function GetMissingPriceLogModules()
	local missing = {}
	if not _G.TSM_POST_SCAN_LOGGER_LOADED then
		table.insert(missing, "TSM_PostScan")
	end
	if not _G.TSM_CANCEL_SCAN_LOGGER_LOADED then
		table.insert(missing, "TSM_CancelScan")
	end
	return #missing > 0 and table.concat(missing, ", ") or nil
end

_G.TSMDBG = {
	Log = noop,
	Warn = noop,
	LogErr = noop,
	Dump = noop,
	Time = noop,
	TimeEnd = noop,
	SignalQuerySent = noop,
	SignalScanComplete = noop,
	captureBlocked = noop,
	GetBlocked = function() return {} end,
	PriceLogReset = PriceLogReset,
	PriceLogBegin = PriceLogBegin,
	PriceLogDecision = PriceLogDecision,
	PriceLogRawAuction = PriceLogRawAuction,
	PriceLogTrace = PriceLogTrace,
	PriceLogEnd = PriceLogEnd,
	GetMissingPriceLogModules = GetMissingPriceLogModules,
}

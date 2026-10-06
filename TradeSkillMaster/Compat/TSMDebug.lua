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
local MAIL_TRACE_VERSION = 1
local MAIL_TRACE_MAX_ENTRIES = 400

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

local function MailTraceDatabase()
	local database = _G.TSMMailDebugDB
	if type(database) ~= "table" or database.version ~= MAIL_TRACE_VERSION or type(database.entries) ~= "table" then
		database = {
			version = MAIL_TRACE_VERSION,
			enabled = false,
			nextSequence = 1,
			entries = {},
		}
		_G.TSMMailDebugDB = database
	end
	database.nextSequence = tonumber(database.nextSequence) or (#database.entries + 1)
	if database.enabled == nil then
		database.enabled = false
	end
	return database
end

local function MailTraceEncode(value)
	local ok, result = pcall(tostring, value)
	if not ok then
		result = "<tostring error>"
	end
	result = result
		:gsub("\\", "\\\\")
		:gsub("|", "\\p")
		:gsub("\r", "\\r")
		:gsub("\n", "\\n")
	return result
end

local function MailTrace(event, fields)
	local database = MailTraceDatabase()
	if not database.enabled then
		return
	end
	local now = type(GetTime) == "function" and GetTime() or time()
	local parts = {
		tostring(database.nextSequence),
		MailTraceEncode(now),
		MailTraceEncode(event),
	}
	database.nextSequence = database.nextSequence + 1
	if type(fields) == "table" then
		local keys = {}
		for key in pairs(fields) do
			table.insert(keys, key)
		end
		table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
		for _, key in ipairs(keys) do
			table.insert(parts, MailTraceEncode(key).."="..MailTraceEncode(fields[key]))
		end
	end
	table.insert(database.entries, table.concat(parts, "|"))
	if #database.entries > MAIL_TRACE_MAX_ENTRIES then
		table.remove(database.entries, 1)
	end
end

local function MailTraceReset()
	_G.TSMMailDebugDB = {
		version = MAIL_TRACE_VERSION,
		enabled = true,
		nextSequence = 1,
		entries = {},
	}
end

local function MailTraceSetEnabled(enabled)
	MailTraceDatabase().enabled = enabled and true or false
end

local function GetMailTrace()
	return MailTraceDatabase().entries
end

local mailTraceHooks = {}

local function InstallMailTraceHooks()
	if type(_G.AutoLootMailItem) == "function" and not mailTraceHooks.AutoLootMailItem then
		mailTraceHooks.AutoLootMailItem = _G.AutoLootMailItem
		_G.AutoLootMailItem = function(index, ...)
			MailTrace("WOW_API_AUTOLOOT", { index = index })
			return mailTraceHooks.AutoLootMailItem(index, ...)
		end
	end
	if type(_G.TakeInboxItem) == "function" and not mailTraceHooks.TakeInboxItem then
		mailTraceHooks.TakeInboxItem = _G.TakeInboxItem
		_G.TakeInboxItem = function(index, subIndex, ...)
			MailTrace("WOW_API_TAKE_ITEM", { index = index, subIndex = subIndex })
			return mailTraceHooks.TakeInboxItem(index, subIndex, ...)
		end
	end
	if type(_G.TakeInboxMoney) == "function" and not mailTraceHooks.TakeInboxMoney then
		mailTraceHooks.TakeInboxMoney = _G.TakeInboxMoney
		_G.TakeInboxMoney = function(index, ...)
			MailTrace("WOW_API_TAKE_MONEY", { index = index })
			return mailTraceHooks.TakeInboxMoney(index, ...)
		end
	end
end

local function MailTraceCommand(message)
	local command, argument = tostring(message or ""):match("^%s*(%S*)%s*(.-)%s*$")
	command = command:lower()
	if command == "reset" or command == "start" then
		MailTraceReset()
		print("TSM mail debug: zapis rozpoczęty, log wyczyszczony.")
	elseif command == "stop" then
		MailTraceSetEnabled(false)
		print("TSM mail debug: zapis zatrzymany.")
	else
		local entries = GetMailTrace()
		local limit = tonumber(argument)
		if command ~= "show" then
			limit = tonumber(command)
		end
		limit = math.max(1, math.min(limit or 80, MAIL_TRACE_MAX_ENTRIES))
		local first = math.max(1, #entries - limit + 1)
		print("TSM mail debug: "..#entries.." wpisów; pokazuję "..(#entries - first + 1)..".")
		for index = first, #entries do
			print(entries[index])
		end
	end
end

_G.SlashCmdList = _G.SlashCmdList or {}
_G.SLASH_TSMMAILDEBUG1 = "/tsmmaildebug"
_G.SlashCmdList.TSMMAILDEBUG = MailTraceCommand
InstallMailTraceHooks()

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
	MailTrace = MailTrace,
	MailTraceReset = MailTraceReset,
	MailTraceSetEnabled = MailTraceSetEnabled,
	GetMailTrace = GetMailTrace,
	InstallMailTraceHooks = InstallMailTraceHooks,
}

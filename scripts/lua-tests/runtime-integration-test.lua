local passed, failures = 0, 0

unpack = unpack or table.unpack
tinsert = table.insert
tremove = table.remove
floor = math.floor
ceil = math.ceil
min = math.min
max = math.max
format = string.format
strfind = string.find
strmatch = string.match
strlower = string.lower
strsub = string.sub
strrep = string.rep
gsub = string.gsub
strbyte = string.byte
strlen = string.len
strlenutf8 = string.len
strtrim = function(value) return (string.gsub(value, "^%s*(.-)%s*$", "%1")) end
sort = table.sort
date = os.date
time = os.time

function wipe(tbl)
	for key in pairs(tbl) do
		tbl[key] = nil
	end
	return tbl
end

function CopyTable(tbl)
	local result = {}
	for key, value in pairs(tbl) do
		result[key] = type(value) == "table" and CopyTable(value) or value
	end
	return result
end

function newproxy()
	-- WoW Lua 5.1 returns userdata. A fresh coroutine has the two properties the
	-- addon relies on here: non-table type and unique identity.
	return coroutine.create(function() end)
end

function strjoin(sep, ...)
	local values = {}
	for i = 1, select("#", ...) do
		values[i] = tostring(select(i, ...))
	end
	return table.concat(values, sep)
end

function strsplit(sep, value)
	local values = {}
	local start = 1
	while true do
		local pos = string.find(value, sep, start, true)
		if not pos then
			tinsert(values, string.sub(value, start))
			break
		end
		tinsert(values, string.sub(value, start, pos - 1))
		start = pos + #sep
	end
	return unpack(values)
end

function debugstack()
	return ""
end

function geterrorhandler()
	return function(err) error(err) end
end

function securecallfunction(func, ...)
	return func(...)
end

local function run(name, func)
	local ok, err = pcall(func)
	if ok then
		passed = passed + 1
		print("PASS: "..name)
	else
		failures = failures + 1
		print("FAIL: "..name.." -> "..tostring(err))
	end
end

local function loadSource(source, name, addonTable, suffix)
	local chunk, err = load(source..(suffix or ""), name)
	assert(chunk, err)
	return chunk(nil, addonTable)
end

-- The component graph and transport layers below are the real addon sources.
WOW_PROJECT_CLASSIC = 1
WOW_PROJECT_BURNING_CRUSADE_CLASSIC = 2
WOW_PROJECT_WRATH_CLASSIC = 3
WOW_PROJECT_MISTS_CLASSIC = 4
WOW_PROJECT_MAINLINE = 5
WOW_PROJECT_ID = WOW_PROJECT_WRATH_CLASSIC
C_AddOns = { GetAddOnMetadata = function() return "v4.14.66" end }
SlashCmdList = {}
TSMMailDebugDB = nil

loadSource(R_TSM_DEBUG, "Compat/TSMDebug.lua")

run("mail trace is bounded, controllable, and exposes persistent entries", function()
	assert(type(TSMDBG.MailTraceReset) == "function", "mail trace reset API is missing")
	assert(type(TSMDBG.MailTrace) == "function", "mail trace write API is missing")
	assert(type(TSMDBG.MailTraceSetEnabled) == "function", "mail trace enable API is missing")
	assert(type(TSMDBG.GetMailTrace) == "function", "mail trace read API is missing")
	TSMDBG.MailTrace("BEFORE_OPT_IN", { index = 0 })
	assert(#TSMDBG.GetMailTrace() == 0, "mail trace must be disabled until explicitly started")
	TSMDBG.MailTraceReset()
	for index = 1, 405 do
		TSMDBG.MailTrace("BOUNDARY", { index = index })
	end
	local entries = TSMDBG.GetMailTrace()
	assert(#entries == 400, "mail trace retained "..#entries.." entries instead of 400")
	assert(strfind(entries[1], "|BOUNDARY|index=6", 1, true), "mail trace encoded a spurious field: "..entries[1])
	assert(strfind(entries[1], "index=6", 1, true), "mail trace did not evict the oldest entries")
	assert(strfind(entries[#entries], "index=405", 1, true), "mail trace lost the newest entry")
	TSMDBG.MailTraceSetEnabled(false)
	TSMDBG.MailTrace("DISABLED", { index = 406 })
	assert(#TSMDBG.GetMailTrace() == 400, "disabled mail trace still recorded data")
	TSMDBG.MailTraceReset()
	assert(#TSMDBG.GetMailTrace() == 0, "mail trace reset did not clear entries")
	assert(type(SlashCmdList.TSMMAILDEBUG) == "function", "/tsmmaildebug command is not registered")
end)

assert(load(R_LIBSTUB, "LibStub.lua"))()
assert(load(R_CLASS, "LibTSMClass.lua"))()

local addonTable = {}
loadSource(R_CORE, "LibTSMCore/Core.lua", addonTable)
local clock = 100
addonTable.LibTSMCore.SetTimeFunction(function() return clock end)
loadSource(R_UTIL_CORE, "LibTSMUtil/Source/Core.lua", addonTable)
loadSource(R_DEBUG_STACK, "DebugStack.lua", addonTable)
loadSource(R_MATH, "Math.lua", addonTable)
loadSource(R_TABLE, "Table.lua", addonTable)
loadSource(R_VARARG, "Vararg.lua", addonTable)
loadSource(R_STRING, "String.lua", addonTable)
loadSource(R_ENUM, "EnumType.lua", addonTable)
loadSource(R_FUTURE, "Future.lua", addonTable)
loadSource(R_ITERATOR, "Iterator.lua", addonTable)
loadSource(R_NAMED_TUPLE_LIST, "NamedTupleList.lua", addonTable)
loadSource(R_OBJECT_POOL, "ObjectPool.lua", addonTable)
loadSource(R_SMART_MAP, "SmartMap.lua", addonTable)
loadSource(R_TEMP_TABLE, "TempTable.lua", addonTable)
loadSource(R_BINARY_SEARCH, "BinarySearch.lua", addonTable)
loadSource(R_HASH, "Hash.lua", addonTable)
loadSource(R_LOG, "Log.lua", addonTable)
loadSource(R_FSM_STATE, "FSM/State.lua", addonTable)
loadSource(R_FSM_OBJECT, "FSM/Object.lua", addonTable)
loadSource(R_FSM, "FSM/FSM.lua", addonTable)
loadSource(R_REACTIVE_PUBLISHER, "Reactive/Publisher.lua", addonTable)
loadSource(R_REACTIVE_EXPRESSION, "Reactive/Expression.lua", addonTable)
loadSource(R_REACTIVE_STATE, "Reactive/State.lua", addonTable)
loadSource(R_REACTIVE_STATE_SCHEMA, "Reactive/StateSchema.lua", addonTable)
loadSource(R_REACTIVE_STREAM, "Reactive/Stream.lua", addonTable)
loadSource(R_REACTIVE, "Reactive.lua", addonTable)
loadSource(R_DATABASE_UTIL, "Database/Util.lua", addonTable)
loadSource(R_DATABASE_ROW, "Database/Row.lua", addonTable)
loadSource(R_DATABASE_QUERY_CLAUSE, "Database/QueryClause.lua", addonTable)
loadSource(R_DATABASE_QUERY, "Database/Query.lua", addonTable)
loadSource(R_DATABASE_TABLE, "Database/Table.lua", addonTable)
loadSource(R_DATABASE_SCHEMA, "Database/Schema.lua", addonTable)
loadSource(R_DATABASE, "Database.lua", addonTable)

addonTable.LibTSMData = addonTable.LibTSMCore.NewComponent("LibTSMData")
loadSource(R_TYPES_CORE, "LibTSMTypes/Source/Core.lua", addonTable)
local itemString = addonTable.LibTSMTypes:Init("Item.ItemString")
function itemString.Get(value) return value end
function itemString.ToId(value) return tonumber(strmatch(value or "", "i:(%d+)")) end
function itemString.GetBase(value) return value end
function itemString.GetBaseFast(value) return value end
function itemString.ToLevel(value) return value end
function itemString.IsLevel() return false end
function itemString.GetUnknown() return "i:0" end
function itemString.GetPetCage() return "i:82800" end
local smartMap = addonTable.LibTSMUtil:IncludeClassType("SmartMap")
local baseMap = smartMap.New("string", "string", function(value) return value end)
local levelMap = smartMap.New("string", "string", function(value) return value end)
function itemString.GetBaseMap() return baseMap end
function itemString.GetLevelMap() return levelMap end
loadSource(R_EVENT_WAITER, "EventWaiter.lua", addonTable)
loadSource(R_FUNCTION_WAITER, "FunctionWaiter.lua", addonTable)
loadSource(R_FUTURE_WAITER, "FutureWaiter.lua", addonTable)
loadSource(R_SCHEDULER, "Scheduler.lua", addonTable)
loadSource(R_THREAD, "Thread.lua", addonTable)
loadSource(R_THREADING, "Threading.lua", addonTable)

loadSource(R_WOW_CORE, "LibTSMWoW/Source/Core.lua", addonTable)
local clientInfo = addonTable.LibTSMWoW:Init("Util.ClientInfo")
clientInfo.FEATURES = { C_AUCTION_HOUSE = 1, CRAFTING_ORDERS = 2 }
function clientInfo.IsRetail() return false end
function clientInfo.IsPandaClassic() return false end
function clientInfo.IsVanillaClassic() return false end
function clientInfo.HasFeature() return false end

local scheduledTimers = {}
local delayTimerClass = addonTable.LibTSMWoW:DefineClassType("DelayTimer")
function delayTimerClass.__static.New(_, callback)
	local timer = { callback = callback, deadline = nil }
	function timer:RunForTime(delay)
		self.deadline = clock + delay
		scheduledTimers[self] = true
	end
	function timer:RunForFrames()
		self:RunForTime(0)
	end
	function timer:Cancel()
		self.deadline = nil
		scheduledTimers[self] = nil
	end
	function timer:Fire()
		self:Cancel()
		return self.callback()
	end
	return timer
end

AUCTION_EXPIRED_MAIL_SUBJECT = "Auction expired: %s"
AUCTION_REMOVED_MAIL_SUBJECT = "Auction cancelled: %s"
AUCTION_OUTBID_MAIL_SUBJECT = "Outbid on %s"
AUCTION_SOLD_MAIL_SUBJECT = "Auction successful: %s"
AUCTION_WON_MAIL_SUBJECT = "Auction won: %s"
AUCTION_HOUSE_MAIL_MULTIPLE_BUYERS = "Multiple Buyers"
AUCTION_HOUSE_MAIL_MULTIPLE_SELLERS = "Multiple Sellers"
ARTISANS_CONSORTIUM = "Artisans"
ATTACHMENTS_MAX_RECEIVE = 12
ATTACHMENTS_MAX_SEND = 12
Enum = { RcoCloseReason = {} }
C_Mail = {
	GetCraftingOrderMailInfo = function() return {} end,
	IsCommandPending = function() return false end,
}

local mails = {}
local lootLog = {}
local requestLog = {}
local accountingEntryLog = {}
local classifyLog = {}
local asyncRemoval = false
local pendingRemoval = nil
local queueServerCommands = false
local serverQueue = {}
local unrelatedMailArrivalAt = nil
local unrelatedMailArrived = false
local inboxReorderAt = nil
local inboxReordered = false

local function addMail(row)
	row.money = row.money or 0
	row.cod = row.cod or 0
	row.numItems = row.numItems or 0
	row.daysLeft = row.daysLeft or 30
	row.canReply = row.canReply == nil and true or row.canReply
	row.attachments = row.attachments or {}
	if row.numItems > 0 and not row.attachments[1] then
		row.attachments[1] = { name = row.subject, link = "i:"..tostring(1000 + #mails + 1), quantity = 1 }
	end
	tinsert(mails, row)
end

local function resetMails()
	if RUNTIME_ACCOUNTING_MAIL_PRIVATE and RUNTIME_ACCOUNTING_MAIL_PRIVATE.rescanTimer then
		RUNTIME_ACCOUNTING_MAIL_PRIVATE.rescanTimer:Cancel()
		wipe(RUNTIME_ACCOUNTING_MAIL_PRIVATE.rescanContext)
	end
	wipe(mails)
	wipe(lootLog)
	wipe(requestLog)
	wipe(accountingEntryLog)
	wipe(classifyLog)
	wipe(serverQueue)
	asyncRemoval = false
	pendingRemoval = nil
	queueServerCommands = false
	unrelatedMailArrivalAt = nil
	unrelatedMailArrived = false
	inboxReorderAt = nil
	inboxReordered = false
	addMail({ subject = "Auction successful: Sold", money = 100 })
	addMail({ subject = "Auction won: Bought", numItems = 1, invoiceType = "buyer" })
	addMail({ subject = "Auction cancelled: Cancelled", numItems = 1 })
	addMail({ subject = "Auction expired: Expired", numItems = 1 })
	addMail({ subject = "A gift", numItems = 1, sender = "Friend" })
end

local function processServerEvents()
	if inboxReorderAt and not inboxReordered and clock >= inboxReorderAt then
		inboxReordered = true
		mails[1], mails[2] = mails[2], mails[1]
	end
	if unrelatedMailArrivalAt and not unrelatedMailArrived and clock >= unrelatedMailArrivalAt then
		unrelatedMailArrived = true
		addMail({ subject = "Auction won: Unrelated arrival", numItems = 1, invoiceType = "buyer" })
	end
	if pendingRemoval and clock >= pendingRemoval.deadline then
		assert(mails[pendingRemoval.index] == pendingRemoval.row, "async inbox index changed before confirmation")
		tinsert(lootLog, pendingRemoval.row.subject)
		tremove(mails, pendingRemoval.index)
		pendingRemoval = nil
	end
end

function GetInboxNumItems()
	processServerEvents()
	return #mails, #mails
end

function GetInboxHeaderInfo(index)
	processServerEvents()
	local row = mails[index]
	if not row then
		return nil
	end
	return nil, row.texture, row.sender or "Auction House", row.subject, row.money, row.cod, row.daysLeft, row.numItems, false, false, row.textCreated or false, row.canReply, row.isGM or false
end

function GetInboxInvoiceInfo(index)
	local row = mails[index]
	if not row then return nil end
	return row.invoiceType, row.itemName, row.playerName, row.bid or 0, row.buyout or 0, row.deposit or 0, row.consignment or 0, nil, row.etaHour, row.etaMin, row.count
end

function GetInboxText()
	return "", nil, nil, true
end

function GetInboxItem(index, attachIndex)
	local row = mails[index]
	if row and row.attachmentReadyAt and clock < row.attachmentReadyAt then
		return nil
	end
	local item = row and row.attachments[attachIndex or 1]
	if item then
		return item.name, item.texture or 0, item.quantity, item.quality or 1, true
	end
end

function GetInboxItemLink(index, attachIndex)
	local row = mails[index]
	if row and row.attachmentReadyAt and clock < row.attachmentReadyAt then
		return nil
	end
	local item = row and row.attachments[attachIndex or 1]
	return item and item.link or nil
end

function AutoLootMailItem(index)
	local row = assert(mails[index], "loot used a stale index "..tostring(index))
	tinsert(requestLog, { index = index, subject = row.subject })
	if queueServerCommands then
		tinsert(serverQueue, index)
	elseif asyncRemoval then
		assert(not pendingRemoval, "started a second loot before the first was confirmed")
		pendingRemoval = { index = index, row = row, deadline = clock + 0.22 }
	else
		tinsert(lootLog, row.subject)
		tremove(mails, index)
	end
end

local function flushServerQueue()
	for _, index in ipairs(serverQueue) do
		local row = mails[index]
		if row then
			tinsert(lootLog, row.subject)
			tremove(mails, index)
		end
	end
	wipe(serverQueue)
end

function DeleteInboxItem(index)
	tremove(mails, index)
end

function TakeInboxItem() end
function TakeInboxMoney() end
function SendMail() end
function GetSendMailCOD() return 0 end
function GetSendMailMoney() return 0 end
function GetSendMailPrice() return 0 end
function GetSendMailItem() return nil end
function GetMoney() return 0 end
function GetLocale() return "enUS" end
function CalculateTotalNumberOfFreeBagSlots() return 20 end
function CheckInbox() end
NUM_BAG_SLOTS = 4
function GetContainerNumFreeSlots() return 20 end
function IsShiftKeyDown() return false end
function IsControlKeyDown() return false end
function UnitName() return "Tester" end
function ReloadUI() end
function GetTime() return clock end

if TSMDBG.InstallMailTraceHooks then
	TSMDBG.InstallMailTraceHooks()
end

loadSource(R_INBOX, "Inbox.lua", addonTable)
loadSource(R_SERVICE_CORE, "LibTSMService/Source/Core.lua", addonTable)

local money = addonTable.LibTSMUtil:Init("UI.Money")
function money.ToStringForUI(value) return tostring(value) end
local mailService = addonTable.LibTSMService:Init("Mail")
function mailService.GetInboxItemLink() return nil end
function mailService.RegisterMailCallback() end
local itemInfoService = addonTable.LibTSMService:Init("Item.ItemInfo")
function itemInfoService.GetLink(item) return item end
function itemInfoService.GetMaxStack() return 20 end
function itemInfoService.GetName(item) return item end
function itemInfoService.ItemNameToItemString(name) return name and "i:1" or nil end
local auctionService = addonTable.LibTSMService:Init("Auction")
function auctionService.GetSaleHintItemString() return nil end
local bagTracking = addonTable.LibTSMService:Init("Inventory.BagTracking")
function bagTracking.GetTotalQuantity() return 0 end
function bagTracking.ItemWillGoInBag() return true end
local chatMessage = addonTable.LibTSMService:Init("UI.ChatMessage")
function chatMessage.PrintUser() end
function chatMessage.PrintfUser() end
local theme = addonTable.LibTSMService:Init("UI.Theme")
function theme.GetColor() return { ColorText = function(_, value) return value end } end
local textureAtlas = addonTable.LibTSMService:Init("UI.TextureAtlas")

local defaultUI = addonTable.LibTSMWoW:Init("UI.DefaultUI")
function defaultUI.RegisterMailVisibleCallback() end
function defaultUI.IsMailVisible() return true end
local event = addonTable.LibTSMWoW:Init("Service.Event")
function event.Register() end
local tooltipScanning = addonTable.LibTSMWoW:Init("Service.TooltipScanning")
function tooltipScanning.GetInboxBattlePetInfo() return nil end
function tooltipScanning.GetInboxMaxUnique() return 0 end
local container = addonTable.LibTSMWoW:Init("API.Container")
function container.GetNumBags() return 0 end
function container.GetNumSlots() return 1 end
function container.GetItemLink() return nil end
function container.GetStackCount() return 0 end
local soundAlert = addonTable.LibTSMWoW:Init("UI.SoundAlert")
function soundAlert.Play() end

loadSource(R_MAIL_UTIL, "Mail/Util.lua", addonTable)
loadSource(R_MAIL_SCANNER, "Mail/Scanner.lua", addonTable, "\nRUNTIME_MAIL_SCANNER_PRIVATE = private\n")

addonTable.LibTSMCore.LoadAll()
local mailScanner = addonTable.LibTSMService:Include("Mail.Scanner")
local threading = addonTable.LibTSMTypes:Include("Threading")
local schedulerRequested = false
local threadErrors = {}
threading.Configure(
	function(err) tinsert(threadErrors, tostring(err)) end,
	function() end,
	function(value) schedulerRequested = value end
)

local function newSettingsDB()
	local view = { keepMailSpace = 0, inboxMessages = false, openMailSound = "none" }
	function view:AddKey() return self end
	return { NewView = function() return view end }
end

local openPackage = {}
local accountingMailPackage = {}
local inboxUIPackage = { ResetRefreshCountdown = function() end, IsMailOpened = function() return false end }
local mailingUI = { Inbox = inboxUIPackage }
function mailingUI:NewPackage(name)
	assert(name == "Inbox")
	inboxUIPackage = {}
	self.Inbox = inboxUIPackage
	return inboxUIPackage
end
function mailingUI.RegisterTopLevelPage() end

local localeTable = setmetatable({}, { __index = function(_, key) return key end })
local uiElements = { New = function() error("visual UI should not be built in this test") end }
local uiUtils = {}

TSMAddon = {
	LibTSMUtil = addonTable.LibTSMUtil,
	LibTSMTypes = addonTable.LibTSMTypes,
	LibTSMWoW = addonTable.LibTSMWoW,
	LibTSMService = addonTable.LibTSMService,
	LibTSMUI = {
		Include = function(_, name)
			if name == "Util.UIElements" then return uiElements end
			if name == "Util.UIUtils" then return uiUtils end
			error(name)
		end,
	},
	Locale = { GetTable = function() return localeTable end },
	Mailing = {
		NewPackage = function(_, name)
			assert(name == "Open")
			return openPackage
		end,
		Inbox = { CreateQuery = function() error("classic path must not use tracking DB") end },
	},
	Accounting = {
		NewPackage = function(_, name)
			assert(name == "Mail")
			return accountingMailPackage
		end,
		Transactions = {
			InsertAuctionSale = function() end,
			InsertAuctionBuy = function() end,
			InsertCODBuy = function() end,
			InsertCODSale = function() end,
		},
		Money = {
			InsertCraftingOrderIncome = function() end,
			InsertCraftingOrderExpense = function() end,
			InsertMoneyTransferIncome = function() end,
			InsertMoneyTransferExpense = function() end,
			InsertPostageExpense = function() end,
		},
		Auctions = {
			InsertExpire = function() end,
			InsertCancel = function() end,
		},
	},
	UI = { MailingUI = mailingUI },
}

loadSource(R_ACCOUNTING_MAIL, "Accounting/Service/Mail.lua", nil, "\nRUNTIME_ACCOUNTING_MAIL_PRIVATE = private\n")
accountingMailPackage.OnInitialize()
local accountingAutoLootMailItem = AutoLootMailItem
AutoLootMailItem = function(index, ...)
	local row = mails[index]
	tinsert(accountingEntryLog, { index = index, subject = row and row.subject or nil })
	return accountingAutoLootMailItem(index, ...)
end

loadSource(R_OPEN, "Mailing/Service/Open.lua", nil, "\nRUNTIME_OPEN_PRIVATE = private\n")
TSMAddon.Mailing.Open = openPackage
loadSource(R_MAIL_UI, "Mailing/UI/MailingUI_Inbox.lua", nil, "\nRUNTIME_MAIL_UI_PRIVATE = private\n")

openPackage.OnInitialize(newSettingsDB())
inboxUIPackage.OnInitialize(newSettingsDB())

local realInbox = addonTable.LibTSMWoW:Include("API.Inbox")
local originalGetMailType = realInbox.GetMailType
realInbox.GetMailType = function(index)
	local mailType = originalGetMailType(index)
	tinsert(classifyLog, { index, mails[index] and mails[index].subject, tostring(mailType) })
	return mailType
end

local fakeFrame = { HasChildById = function() return false end }
local fakeCancelButton = {
	GetContext = function() return realInbox.MAIL_TYPE.CANCEL end,
	SetPressed = function() end,
}

local function processDueTimers()
	local firedTimer = true
	local timerIterations = 0
	while firedTimer do
		firedTimer = false
		timerIterations = timerIterations + 1
		assert(timerIterations < 100, "timers did not quiesce")
		for timer in pairs(scheduledTimers) do
			if timer.deadline and timer.deadline <= clock then
				timer:Fire()
				firedTimer = true
				break
			end
		end
	end
end

local function drainScheduler(step)
	local iterations = 0
	while threading.HasAliveThread() do
		iterations = iterations + 1
		assert(iterations < 1000, "scheduler did not quiesce")
		-- Default whole-second ticks avoid Fengari's stricter `%d` handling.
		-- Host Lua 5.1 can use finer ticks for the sub-second refresh regression.
		clock = clock + (step or 1)
		processDueTimers()
		threading.RunScheduler(0.01)
	end
	assert(#threadErrors == 0, table.concat(threadErrors, " | "))
	assert(not schedulerRequested, "scheduler remained requested after thread exit")
end

local function setClassificationMatrixMails()
	resetMails()
	wipe(mails)
	addMail({ subject = "Auction successful: Sold", money = 120, invoiceType = "seller" })
	addMail({ subject = "Auction won: Bought", numItems = 1, invoiceType = "buyer" })
	addMail({ subject = "Auction cancelled: Cancelled", numItems = 1 })
	addMail({ subject = "Auction cancelled: Bid refund", money = 50, numItems = 1 })
	addMail({ subject = "Auction expired: Expired", numItems = 1 })
	addMail({ subject = "Temporary invoice", invoiceType = "seller_temp_invoice" })
	addMail({ subject = "Outbid on Jade", money = 50 })
	addMail({ subject = "Gold and item", sender = "Friend", money = 10, numItems = 1 })
	addMail({ subject = "Gold only", sender = "Friend", money = 10 })
	addMail({ subject = "Item only", sender = "Friend", numItems = 1 })
	addMail({ subject = "GM notice", sender = "GM", isGM = true })
	addMail({ subject = "COD", sender = "Friend", cod = 10, numItems = 1 })
	addMail({ subject = "Empty letter", sender = "Friend" })
end

local function getClassificationMatrix(inbox)
	return {
		inbox.MAIL_TYPE.SALE.AUCTION,
		inbox.MAIL_TYPE.BUY.AUCTION,
		inbox.MAIL_TYPE.CANCEL.AUCTION,
		inbox.MAIL_TYPE.CANCEL.BID,
		inbox.MAIL_TYPE.EXPIRE.AUCTION,
		inbox.MAIL_TYPE.OTHER.TEMP_INVOICE,
		inbox.MAIL_TYPE.OTHER.OUTBID,
		inbox.MAIL_TYPE.OTHER.GOLD_AND_ITEMS,
		inbox.MAIL_TYPE.OTHER.GOLD,
		inbox.MAIL_TYPE.OTHER.ITEMS,
		inbox.MAIL_TYPE.LETTER.GM,
		inbox.MAIL_TYPE.LETTER.COD,
		inbox.MAIL_TYPE.LETTER.EMPTY,
	}
end

local function pipelineTrace()
	local result = {}
	for i, entry in ipairs(classifyLog) do
		tinsert(result, format("classify[%d]=%s:%s:%s", i, tostring(entry[1]), tostring(entry[2]), tostring(entry[3])))
	end
	for i, entry in ipairs(requestLog) do
		tinsert(result, format("native[%d]=%s:%s", i, tostring(entry.index), tostring(entry.subject)))
	end
	for i, entry in ipairs(accountingEntryLog) do
		tinsert(result, format("accounting[%d]=%s:%s", i, tostring(entry.index), tostring(entry.subject)))
	end
	for i, subject in ipairs(lootLog) do
		tinsert(result, format("loot[%d]=%s", i, tostring(subject)))
	end
	return table.concat(result, " | ")
end

local function assertMailTraceEventsInOrder(expectedEvents)
	local entries = TSMDBG.GetMailTrace()
	local nextEntry = 1
	for _, eventName in ipairs(expectedEvents) do
		local found = false
		for index = nextEntry, #entries do
			if strfind(entries[index], "|"..eventName.."|", 1, true) then
				found = true
				nextEntry = index + 1
				break
			end
		end
		assert(found, "missing or out-of-order mail trace event "..eventName..": "..table.concat(entries, " || "))
	end
end

run("Inbox classifies every supported mail shape into its literal category", function()
	setClassificationMatrixMails()
	local expected = getClassificationMatrix(realInbox)
	for index, expectedType in ipairs(expected) do
		local actualType = originalGetMailType(index)
		assert(actualType == expectedType, format("mail %d (%s) classified as %s instead of %s", index, mails[index].subject, tostring(actualType), tostring(expectedType)))
	end
end)

run("real Mail.Scanner stores the same categories produced by live Inbox", function()
	setClassificationMatrixMails()
	local expected = getClassificationMatrix(realInbox)
	mailScanner.Load({})
	RUNTIME_MAIL_SCANNER_PRIVATE.MailInboxUpdateDelayed()
	local stored = {}
	local query = mailScanner.NewMailQuery()
		:Select("index", "type")
		:OrderBy("index", true)
	for _, index, mailType in query:Iterator() do
		stored[index] = mailType
	end
	query:Release()
	for index, expectedType in ipairs(expected) do
		assert(stored[index] == expectedType, format("scanner/live mismatch at %d (%s): %s vs %s", index, mails[index].subject, tostring(stored[index]), tostring(expectedType)))
	end
end)

run("real UI/FSM/Threading Cancelled path loots only cancelled mail", function()
	resetMails()
	RUNTIME_MAIL_UI_PRIVATE.fsm:ProcessEvent("EV_FRAME_SHOW", fakeFrame, "")
	RUNTIME_MAIL_UI_PRIVATE.OpenCancelsBtnOnClick(fakeCancelButton)
	drainScheduler()
	assert(#lootLog == 1, "loot count="..#lootLog.." ["..table.concat(lootLog, ", ").."]")
	assert(lootLog[1] == "Auction cancelled: Cancelled", "wrong mail looted: "..tostring(lootLog[1]))
	assert(#mails == 4, "collector removed non-cancel mail")
end)

run("delayed Classic inbox mutation keeps category isolation", function()
	resetMails()
	asyncRemoval = true
	RUNTIME_MAIL_UI_PRIVATE.OpenCancelsBtnOnClick(fakeCancelButton)
	drainScheduler()
	assert(#lootLog == 1, "async loot count="..#lootLog.." ["..table.concat(lootLog, ", ").."]")
	assert(lootLog[1] == "Auction cancelled: Cancelled", "wrong async mail looted: "..tostring(lootLog[1]))
	assert(#mails == 4, "async collector removed non-cancel mail")
end)

run("Accounting retry for a loading Cancelled attachment cannot cross into Bought", function()
	resetMails()
	wipe(mails)
	addMail({ subject = "Auction won: Bought", numItems = 1, invoiceType = "buyer" })
	addMail({ subject = "Auction cancelled: Cancelled", numItems = 1, attachmentReadyAt = clock + 0.5 })
	asyncRemoval = true
	RUNTIME_MAIL_UI_PRIVATE.OpenCancelsBtnOnClick(fakeCancelButton)
	drainScheduler()
	assert(#accountingEntryLog == 1, "one category click entered Accounting "..#accountingEntryLog.." times: "..pipelineTrace())
	assert(#requestLog == 1, "one category click reached native API "..#requestLog.." times: "..pipelineTrace())
	assert(#lootLog == 1 and lootLog[1] == "Auction cancelled: Cancelled", "Accounting retry crossed into Bought: "..pipelineTrace())
	assert(#mails == 1 and mails[1].subject == "Auction won: Bought", "Bought mail was removed: "..pipelineTrace())
end)

run("live mail trace covers UI through native API and confirmation", function()
	resetMails()
	wipe(mails)
	addMail({ subject = "Auction won: Bought", numItems = 1, invoiceType = "buyer" })
	addMail({ subject = "Auction cancelled: Cancelled", numItems = 1, attachmentReadyAt = clock + 1.5 })
	TSMDBG.MailTraceReset()
	RUNTIME_MAIL_UI_PRIVATE.OpenCancelsBtnOnClick(fakeCancelButton)
	drainScheduler()
	assertMailTraceEventsInOrder({
		"UI_CLICK",
		"UI_FSM_START",
		"OPEN_START",
		"OPEN_THREAD_CLASSIC",
		"OPEN_CLASSIFY",
		"OPEN_REQUEST",
		"ACCOUNTING_SCAN",
		"ACCOUNTING_RETRY",
		"ACCOUNTING_SCAN",
		"ACCOUNTING_NATIVE",
		"WOW_API_AUTOLOOT",
		"OPEN_CONFIRM",
	})
end)

run("real UI Accounting retry stays bound to Cancelled when inbox indices reorder", function()
	resetMails()
	wipe(mails)
	addMail({ subject = "Auction won: Bought", numItems = 1, invoiceType = "buyer" })
	-- The first scheduler tick starts the request. The second tick runs Accounting's
	-- delayed retry after the server has reordered the two live inbox rows.
	addMail({ subject = "Auction cancelled: Cancelled", numItems = 1, attachmentReadyAt = clock + 1.5 })
	inboxReorderAt = clock + 1.1
	RUNTIME_MAIL_UI_PRIVATE.OpenCancelsBtnOnClick(fakeCancelButton)
	drainScheduler()
	assert(inboxReordered, "inbox reorder was not simulated")
	assert(#lootLog == 1, "Cancelled retry looted "..#lootLog.." mails after reorder: "..pipelineTrace())
	assert(lootLog[1] == "Auction cancelled: Cancelled", "Cancelled retry crossed into "..tostring(lootLog[1])..": "..pipelineTrace())
	assert(#mails == 1 and mails[1].subject == "Auction won: Bought", "Bought mail was removed after reorder: "..pipelineTrace())
end)

run("multiple Cancelled mails are requested strictly one at a time", function()
	resetMails()
	wipe(mails)
	addMail({ subject = "Auction cancelled: Cancelled A", numItems = 1 })
	addMail({ subject = "Auction won: Bought", numItems = 1, invoiceType = "buyer" })
	addMail({ subject = "Auction cancelled: Cancelled B", numItems = 1 })
	asyncRemoval = true
	RUNTIME_MAIL_UI_PRIVATE.OpenCancelsBtnOnClick(fakeCancelButton)
	drainScheduler()
	assert(#requestLog == 2, "expected two confirmed serial requests: "..pipelineTrace())
	assert(#lootLog == 2, "expected two cancelled mails: "..pipelineTrace())
	assert(lootLog[1] == "Auction cancelled: Cancelled B" and lootLog[2] == "Auction cancelled: Cancelled A", "serial order/category mismatch: "..pipelineTrace())
	assert(#mails == 1 and mails[1].subject == "Auction won: Bought", "serial collector crossed into Bought: "..pipelineTrace())
end)

run("Cancelled button cannot degrade to Open All when element context is lost", function()
	resetMails()
	local contextlessButton = {
		GetContext = function() return nil end,
		SetPressed = function() end,
	}
	assert(type(RUNTIME_MAIL_UI_PRIVATE.OpenCancelsBtnOnClick) == "function", "Cancelled needs an explicit category callback")
	RUNTIME_MAIL_UI_PRIVATE.OpenCancelsBtnOnClick(contextlessButton)
	drainScheduler()
	assert(#lootLog == 1, "context loss degraded category click to Open All: "..#lootLog.." mails")
	assert(lootLog[1] == "Auction cancelled: Cancelled", "contextless callback looted "..tostring(lootLog[1]))
end)

run("every category callback stays isolated without element context", function()
	local cases = {
		{ "OpenSalesBtnOnClick", "Auction successful: Sold" },
		{ "OpenBuysBtnOnClick", "Auction won: Bought" },
		{ "OpenCancelsBtnOnClick", "Auction cancelled: Cancelled" },
		{ "OpenExpiresBtnOnClick", "Auction expired: Expired" },
		{ "OpenOthersBtnOnClick", "A gift" },
	}
	local contextlessButton = {
		GetContext = function() return nil end,
		SetPressed = function() end,
	}
	for _, case in ipairs(cases) do
		resetMails()
		RUNTIME_MAIL_UI_PRIVATE[case[1]](contextlessButton)
		drainScheduler()
		assert(#lootLog == 1, case[1].." looted "..#lootLog.." mails")
		assert(lootLog[1] == case[2], case[1].." looted "..tostring(lootLog[1]))
	end
end)

run("Bought callback rejects sold mail with contradictory buyer invoice", function()
	resetMails()
	mails[1].invoiceType = "buyer"
	RUNTIME_MAIL_UI_PRIVATE.OpenBuysBtnOnClick(fakeCancelButton)
	drainScheduler()
	assert(#lootLog == 1, "Bought looted "..#lootLog.." mails")
	assert(lootLog[1] == "Auction won: Bought", "Bought looted "..tostring(lootLog[1]))
end)

run("each real category button loots only mails assigned to its parent group", function()
	local cases = {
		{ "OpenSalesBtnOnClick", "Auction successful: Sold" },
		{ "OpenBuysBtnOnClick", "Auction won: Bought" },
		{ "OpenCancelsBtnOnClick", "Auction cancelled: Cancelled" },
		{ "OpenExpiresBtnOnClick", "Auction expired: Expired" },
		{ "OpenOthersBtnOnClick", "A gift" },
	}
	for _, case in ipairs(cases) do
		resetMails()
		RUNTIME_MAIL_UI_PRIVATE[case[1]](fakeCancelButton)
		drainScheduler()
		assert(#lootLog == 1, case[1].." crossed category boundary: "..pipelineTrace())
		assert(lootLog[1] == case[2], case[1].." looted "..tostring(lootLog[1])..": "..pipelineTrace())
	end
end)

run("unconfirmed Classic request cannot be replayed onto shifted Bought mail", function()
	resetMails()
	TSMDBG.MailTraceReset()
	wipe(mails)
	addMail({ subject = "Auction cancelled: Cancelled", numItems = 1 })
	addMail({ subject = "Auction won: Bought A", numItems = 1, invoiceType = "buyer" })
	addMail({ subject = "Auction won: Bought B", numItems = 1, invoiceType = "buyer" })
	addMail({ subject = "Auction won: Bought C", numItems = 1, invoiceType = "buyer" })
	queueServerCommands = true
	RUNTIME_MAIL_UI_PRIVATE.OpenCancelsBtnOnClick(fakeCancelButton)
	drainScheduler()
	flushServerQueue()
	assert(#requestLog == 1, "same Cancelled index was queued "..#requestLog.." times: "..pipelineTrace())
	assert(#lootLog == 1, "queued Cancelled requests spilled into Bought: "..pipelineTrace())
	assert(lootLog[1] == "Auction cancelled: Cancelled", "wrong server-side target: "..pipelineTrace())
	assertMailTraceEventsInOrder({ "OPEN_REQUEST", "OPEN_CONFIRM", "OPEN_STOP" })
	local hasStopReason = false
	for _, entry in ipairs(TSMDBG.GetMailTrace()) do
		if strfind(entry, "|OPEN_STOP|", 1, true) and strfind(entry, "reason=REQUEST_UNCONFIRMED", 1, true) then
			hasStopReason = true
		end
	end
	assert(hasStopReason, "trace did not distinguish an unconfirmed request from normal completion")
end)

run("unrelated inbox count change cannot confirm a pending Cancelled request", function()
	resetMails()
	wipe(mails)
	addMail({ subject = "Auction cancelled: Cancelled", numItems = 1 })
	addMail({ subject = "Auction won: Bought A", numItems = 1, invoiceType = "buyer" })
	queueServerCommands = true
	unrelatedMailArrivalAt = clock + 0.5
	RUNTIME_MAIL_UI_PRIVATE.OpenCancelsBtnOnClick(fakeCancelButton)
	drainScheduler()
	flushServerQueue()
	assert(unrelatedMailArrived, "unrelated inbox change was not simulated")
	assert(#requestLog == 1, "unrelated count change confirmed and replayed a stale index: "..pipelineTrace())
	assert(#lootLog == 1 and lootLog[1] == "Auction cancelled: Cancelled", "unrelated change caused cross-category loot: "..pipelineTrace())
end)

run("timeout probe records inventory transfer without authorizing another request", function()
	local originalGetItemCount = GetItemCount
	for _, bagCount in ipairs({ 0, 1 }) do
		resetMails()
		wipe(mails)
		addMail({ subject = "Auction won: Iron Bar", numItems = 1, sender = "Blackwater Auction House", invoiceType = "buyer" })
		TSMDBG.MailTraceReset()
		GetItemCount = function() return bagCount end
		local done, confirmed = RUNTIME_OPEN_PRIVATE.MailActionConfirmed(clock, 1, "Blackwater Auction House", 0, 0, 1, "Auction won: Iron Bar", {
			itemLink = "i:1", bagCount = 0, numLeft = 1, numTotal = 1, freeSlots = 20,
		})
		assert(done and not confirmed, "probe must not use unrelated bag changes to confirm a mail")
		local entry = TSMDBG.GetMailTrace()[1]
		assert(strfind(entry, "|OPEN_TIMEOUT_CONTEXT|", 1, true), "missing timeout context")
		assert(strfind(entry, "bagCount="..bagCount, 1, true), "inventory result not recorded")
		assert(strfind(entry, "prevBagCount=0", 1, true), "inventory baseline not recorded")
		assertMailTraceEventsInOrder({ "OPEN_TIMEOUT_CONTEXT", "OPEN_CONFIRM" })
	end
	GetItemCount = originalGetItemCount
	RUNTIME_OPEN_PRIVATE.isOpening = true
	RUNTIME_OPEN_PRIVATE.TraceMailError("UI_ERROR_MESSAGE", "Inventory is full.")
	local entries = TSMDBG.GetMailTrace()
	assert(strfind(entries[#entries], "message=Inventory is full.", 1, true), "mail UI refusal was lost")
	RUNTIME_OPEN_PRIVATE.isOpening = false
	local count = #entries
	RUNTIME_OPEN_PRIVATE.TraceMailError("UI_ERROR_MESSAGE", "Unrelated error")
	assert(#entries == count, "probe logged an error outside the opening operation")
end)

run("Shift collection waits for fast hidden-mail refill and rebases the live index", function()
	resetMails()
	local originalGetNumItems = GetInboxNumItems
	local originalOpenSingle = RUNTIME_OPEN_PRIVATE.OpenSingleMailClassic
	local originalCanOpen = RUNTIME_OPEN_PRIVATE.CanOpenMail
	local shown, total, refillAt = 2, 3, nil
	local indices, doneCount = {}, 0
	GetInboxNumItems = function()
		if refillAt and clock >= refillAt then
			shown = total
			refillAt = nil
		end
		return shown, total
	end
	RUNTIME_OPEN_PRIVATE.CanOpenMail = function() return true end
	RUNTIME_OPEN_PRIVATE.OpenSingleMailClassic = function(index, keepMoney, filterText, filterType)
		assert(not refillAt, "next request was sent during the server refill")
		assert(index == shown, "collector continued with a stale descending index")
		assert(not keepMoney and filterText == "" and filterType == realInbox.MAIL_TYPE.BUY, "filter lost across refill")
		tinsert(indices, index)
		shown, total = shown - 1, total - 1
		if total > shown then refillAt = clock + 0.15 end
		return true
	end
	openPackage.StartOpening(function() doneCount = doneCount + 1 end, true, false, "", realInbox.MAIL_TYPE.BUY)
	local ok, err = pcall(drainScheduler, _VERSION == "Lua 5.1" and 0.05 or 1)
	GetInboxNumItems = originalGetNumItems
	RUNTIME_OPEN_PRIVATE.OpenSingleMailClassic = originalOpenSingle
	RUNTIME_OPEN_PRIVATE.CanOpenMail = originalCanOpen
	assert(ok, err)
	assert(#indices == 3 and indices[1] == 2 and indices[2] == 2 and indices[3] == 1, "fresh batch was not completely collected")
	assert(doneCount == 1 and total == 0, "collection completed before the refreshed batch was emptied")
end)

print(format("Runtime integration behavior: %d passed, %d failed", passed, failures))
return failures
